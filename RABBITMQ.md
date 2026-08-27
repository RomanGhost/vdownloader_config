# RabbitMQ in vdownloader

How the three services talk to each other, why it's RabbitMQ, and what every
setting in [`internal/mq`](vdownloader_worker/internal/mq) is for.

## Why a message broker at all

A download takes seconds to minutes (yt-dlp + ffmpeg on a 4K file). The Telegram
bot and the web page must **not** block for that. So instead of calling the
worker directly, a front end drops a *job request* into RabbitMQ and returns
immediately; the worker picks the job up when it has capacity and later drops a
*completion notification* back.

This buys three things:

- **Non-blocking submit** — the front end publishes and moves on.
- **Backpressure / durability** — if the worker is down or busy, jobs wait in a
  queue instead of being lost.
- **Horizontal scale** — run N worker copies and RabbitMQ splits the jobs
  between them, no code change.

## Topology

Two **durable queues** on the **default exchange** (so the routing key is just
the queue name):

| Queue | Publishers | Consumer | Payload |
|---|---|---|---|
| `video.jobs` | `vdownloader_telegram`, `vdownloader_web` | `vdownloader_worker` (tag `vdownloader-worker`) | full job request JSON |
| `video.completed` | `vdownloader_worker` | `vdownloader_telegram` (tag `vdownloader-telegram`) | `{"file_id": "..."}` |

```
 telegram ──publish──┐                          ┌──consume── telegram
                     ▼                          │            (edits the chat message,
   web ────publish──► video.jobs ──► worker ──► video.completed   then GET /api/jobs/{id})
                                       │
                                       └─ runs yt-dlp, writes SQLite, serves /files/*
```

`vdownloader_web` does **not** consume `video.completed` — the browser has no
server push, it just polls `GET /api/jobs/{file_id}` every 2 s.

The completion message is deliberately tiny: consumers call
`GET /api/jobs/{file_id}` on the worker to learn the real outcome
(`ready`/`failed`, error text, download URL).

## Core AMQP concepts

| Term | Meaning | Here |
|---|---|---|
| **Broker** | The RabbitMQ server process | the `rabbitmq` container, AMQP on `5672` |
| **Connection** | One TCP connection to the broker | one per `Publisher` / `Consumer` |
| **Channel** | A virtual connection multiplexed over the TCP connection; every operation runs on a channel | `p.ch` in [publisher.go](vdownloader_worker/internal/mq/publisher.go) |
| **Queue** | A named buffer holding messages until they're consumed and acked | `video.jobs`, `video.completed` |
| **Exchange** | Receives published messages, routes them to queues | the **default** exchange (`""`) |
| **Routing key** | String the exchange routes on | the target queue name |
| **Binding** | Exchange→queue link | implicit: the default exchange binds every queue to its own name |
| **Consumer** | Subscription that receives deliveries from a queue | `ch.Consume(...)` in [consumer.go](vdownloader_worker/internal/mq/consumer.go) |
| **Ack** | Consumer tells the broker "handled, delete it" | `d.Ack(false)` after the handler returns |
| **Consumer tag** | Name the consumer registers under | `vdownloader-worker`, `vdownloader-telegram` |

## The `internal/mq` package

The same package is vendored byte-for-byte into all three modules
([worker](vdownloader_worker/internal/mq), [telegram](vdownloader_telegram/internal/mq),
[web](vdownloader_web/internal/mq)). Three files:

### `mq.go`

Queue names as **constants** — `QueueJobs` / `QueueCompleted`. They never vary
between deployments, so they aren't configuration; only `RABBITMQ_URL` is.
`declareQueue` declares a **durable** queue (survives a broker restart). Every
endpoint declares the queues it uses, so start order doesn't matter.

### `publisher.go` — `Publisher`

```go
ch.PublishWithContext(ctx, "" /*default exchange*/, queue /*routing key*/, false, false,
    amqp.Publishing{
        ContentType:  "application/json",
        DeliveryMode: amqp.Persistent, // message body written to disk
        Body:         body,
    })
```

- **Mutex-guarded** — a `*amqp.Channel` is not safe for concurrent publishes,
  and the worker publishes from many download goroutines at once.
- **Redial on a dead channel** — `Publish` retries once with a fresh connection,
  so a broker restart between two publishes is invisible to callers.
- **Eager connect** in `NewPublisher` — a bad `RABBITMQ_URL` fails at startup,
  not on the first job.

### `consumer.go` — `Consumer`

```go
ch.Qos(1, 0, false)                                   // prefetch = 1
deliveries, _ := ch.Consume(queue, tag, false /*autoAck*/, ...)
for d := range deliveries {
    handle(ctx, d.Body)
    d.Ack(false)
}
```

- **`Consume` blocks** until the context is cancelled; on a dropped connection
  it reconnects with a fixed 3 s backoff and re-subscribes.
- **Manual ack** — `autoAck = false`. The message is acked only **after** the
  handler returns. If the process dies before that, RabbitMQ re-queues the
  message for another consumer.
- **Prefetch 1** (`Qos`) — the broker hands a consumer at most one un-acked
  message at a time. With several workers this gives natural load balancing: a
  worker gets the next job only when it has finished (acked) the current one,
  instead of the broker dumping a batch onto whoever connected first.

## The four reliability settings, together

| Setting | Where | Protects against |
|---|---|---|
| durable queue | `QueueDeclare(name, true, …)` | broker restart wiping the queue |
| persistent message | `DeliveryMode: amqp.Persistent` | broker crash losing queued jobs |
| manual ack | `autoAck=false` + `d.Ack` | consumer crash losing an in-flight job |
| prefetch 1 | `ch.Qos(1, 0, false)` | one slow worker hogging the backlog |

### Delivery guarantee, honestly

The worker acks **right after `HandleJobMessage` returns**, and that function
only *starts* the download in a goroutine — it doesn't wait for it. So:

- Job lost before the goroutine starts → RabbitMQ re-delivers it. ✅
- Worker crashes **mid-download** → the job was already acked, so it is **not**
  retried; it stays `pending` in SQLite. ⚠️

This is the same at-most-once-ish behaviour the project had with Kafka
auto-commit. Making downloads survive a mid-flight crash would mean acking only
after the file is finished (and raising RabbitMQ's 30-minute `consumer_timeout`
for un-acked messages) — not done, since a stuck job is easy to resubmit.

## Competing consumers (scaling the worker)

Start two worker containers; both `ch.Consume("video.jobs", …)`. RabbitMQ
round-robins jobs between them, bounded by prefetch. Nothing else to configure.

## Configuration

One env var per service:

| Var | Default |
|---|---|
| `RABBITMQ_URL` | `amqp://guest:guest@localhost:5672/` |

In `docker-compose.yml` it's `amqp://guest:guest@rabbitmq:5672/` (the service
name on the compose network).

## Running the broker

`docker compose up` starts `rabbitmq:3.13-management-alpine`:

| Port | Use |
|---|---|
| `5672` | AMQP — what the services connect to |
| `15672` | Management UI — `http://localhost:15672`, login `guest` / `guest` |

The **management UI** is the first place to look when jobs aren't processed:
open the *Queues* tab and check `video.jobs`. Messages piling up with 0
consumers → the worker isn't connected. Messages not arriving at all → a
publisher problem in the bot or web service.

Useful CLI (inside the container, `docker compose exec rabbitmq …`):

```bash
rabbitmqctl list_queues name messages consumers
rabbitmq-diagnostics -q ping
```

## Why RabbitMQ and not Kafka

| | RabbitMQ | Kafka |
|---|---|---|
| Model | smart broker, per-message state | append-only log, consumer tracks offset |
| A message is | deleted once acked | kept for a retention window, replayable |
| Retry / dead-letter | built in | roll your own |
| Long (minutes) task per message | fine — prefetch + manual ack | awkward — risks consumer-group rebalance |
| Best at | "do this job once" | high-throughput event streaming |

A Telegram video downloader is a **task queue**, which is RabbitMQ's home
ground. Kafka would add operational weight and offset-management headaches for
no benefit at this scale. The library is
[`github.com/rabbitmq/amqp091-go`](https://github.com/rabbitmq/amqp091-go).
