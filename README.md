# vdownloader

A video-downloading system built on [yt-dlp](https://github.com/yt-dlp/yt-dlp), split into three services that talk to each other over RabbitMQ. Each service — and this repo itself — is an independent GitHub repo; this one (`vdownloader_config`) holds the orchestration (`docker-compose.yml`, the smoke test, this doc) and doesn't contain the other three's source:

| Service | Role | Repo |
|---|---|---|
| `vdownloader_worker` | Runs yt-dlp, serves finished files over HTTP, consumes/produces RabbitMQ | [repo](https://github.com/RomanGhost/vdownloader_worker) · [README](https://github.com/RomanGhost/vdownloader_worker/blob/main/README.md) |
| `vdownloader_telegram` | Telegram bot front end | [repo](https://github.com/RomanGhost/vdownloader_telegram) · [README](https://github.com/RomanGhost/vdownloader_telegram/blob/main/README.md) |
| `vdownloader_web` | Browser front end (static page + small Go bridge) | [repo](https://github.com/RomanGhost/vdownloader_web) · [README](https://github.com/RomanGhost/vdownloader_web/blob/master/README.md) |

## Architecture

```
                 ┌──────────────────┐        ┌──────────────────┐
                 │ vdownloader_web   │        │ vdownloader_      │
                 │ (browser + proxy) │        │ telegram (bot)    │
                 └───────┬──────┬────┘        └────┬────────┬────┘
                         │      │                   │        │
              GET /api/formats │        publish video.jobs   │
              GET /api/jobs/*  │        consume video.completed
              GET /files/*     │                   │        │
                         │      └──── video.jobs ───┘        │
                         │                                   │
                         ▼                                   ▼
                 ┌──────────────────────────────────────────────┐
                 │                  RabbitMQ                      │
                 │   queue: video.jobs        (job requests)      │
                 │   queue: video.completed   (job completions)   │
                 └───────────────────────┬────────────────────────┘
                                          │
                                          ▼
                                 ┌──────────────────┐
                                 │ vdownloader_worker │
                                 │  - consumes video.jobs, runs yt-dlp
                                 │  - publishes video.completed
                                 │  - HTTP: GET /api/formats, /api/jobs*, /files/*
                                 └──────────────────┘
```

Only two things ever go over plain HTTP to the worker: **fetching the standardized quality list** for a URL (`GET /api/formats`) and **downloading the finished file** (`GET /files/{file_id}`), plus polling job status (`GET /api/jobs/{file_id}`). Submitting a download job is *always* a RabbitMQ publish to `video.jobs` — the worker has no `POST /api/jobs` endpoint anymore. See [vdownloader_worker's README](https://github.com/RomanGhost/vdownloader_worker/blob/main/README.md#rabbitmq-contract) (a separate repo) for the exact wire format.

How the messaging works end to end — queues, the `internal/mq` package, reliability settings, the management UI, and why RabbitMQ over Kafka — is written up in [RABBITMQ.md](RABBITMQ.md).

## Standardized formats

Neither client shows yt-dlp's raw per-video format list (it varies wildly by site). Instead `GET /api/formats` returns:

- `video_heights`: a subset of the fixed ladder `2160/1440/1080/720/480/360`, restricted to tiers the source can actually deliver — both capped at its real max height *and* only offered when a format genuinely exists at or below that tier. Sparse sources (e.g. Instagram reels that jump straight from ~1280 to ~1920 with nothing in between) don't get tiers that would fail to resolve to any format; sources whose max height sits below the smallest standard tier (360p — old/archival videos) currently offer no video tier at all, only "Audio only".
- `duration`: seconds, `0` if the source doesn't report one (e.g. livestreams). Used by the worker to size the per-job download timeout — see [RabbitMQ contract](https://github.com/RomanGhost/vdownloader_worker/blob/main/README.md#rabbitmq-contract).
- `audio_formats`: always `["mp3", "m4a", "opus", "wav"]` — `mp3` is the default, every target is an ffmpeg transcode so the set never depends on the source.

Both bot and web UI walk the user through a two-step pick: quality tier → with/without audio (video), or "Audio only" → target codec (audio). See [downloader/formats.go](https://github.com/RomanGhost/vdownloader_worker/blob/main/internal/downloader/formats.go) in the worker repo.

A playlist/mix/radio URL (e.g. YouTube's `?list=...`) always resolves to just the single video it points at (`--no-playlist`) — every job is one `file_id` → one file, with no playlist-index in the output path, so downloading a whole list would silently overwrite the same file across items.

Whatever codec the source actually used, output muxed into `mp4`/`mov`/`avi` is guaranteed H.264/AAC: some sites (TikTok's `bytevc1`, VP9, AV1, Opus, ...) hand back a single already-container-wrapped format that skips yt-dlp's own merge/recode postprocessors entirely, so the worker probes the finished file with `ffprobe` and force-transcodes with `ffmpeg` itself when needed, rather than trusting yt-dlp's "is it already this container" check.

## Running everything

```bash
docker compose up --build
```

Brings up RabbitMQ + all three services on one Docker network. Each service declares the durable queues it uses on connect, and reconnects on its own if the broker isn't up yet, so start order doesn't matter (the `depends_on` healthcheck just avoids noisy first-attempt failures). Ports:

| Service | Port |
|---|---|
| worker (HTTP: formats/jobs/files) | `8080` |
| web UI | `8082` |
| RabbitMQ (AMQP) | `5672` |
| RabbitMQ (management UI, guest/guest) | `15672` |

`vdownloader_telegram` needs `BOT_TOKEN` (and RabbitMQ needs `RABBITMQ_USER`/`RABBITMQ_PASS`) — set these in a `.env` file next to this repo's `docker-compose.yml`; Docker Compose loads it automatically and substitutes `${BOT_TOKEN}` etc. into the compose file's `environment:` entries.

## Requirements (bare-metal / non-Docker)

| Tool | Needed by |
|---|---|
| [yt-dlp](https://github.com/yt-dlp/yt-dlp) | worker |
| [ffmpeg](https://ffmpeg.org) | worker (muxing, audio transcodes) |
| [ffprobe](https://ffmpeg.org) | worker (verifying output video codec; ships alongside ffmpeg) |
| [Go 1.24+](https://go.dev) | building any service from source |
| A running RabbitMQ broker | worker, telegram, web |

## Testing

- **Unit tests** (fast, no external services — each service has its own suite, in its own repo). Clone each one as a sibling directory and run `go test ./...` inside it, e.g.:

  ```bash
  git clone https://github.com/RomanGhost/vdownloader_worker && (cd vdownloader_worker && go test ./...)
  git clone https://github.com/RomanGhost/vdownloader_telegram && (cd vdownloader_telegram && go test ./...)
  git clone https://github.com/RomanGhost/vdownloader_web && (cd vdownloader_web && go test ./...)
  ```

  | Service | Covers | Doc |
  |---|---|---|
  | `vdownloader_worker` | Standardized quality ladder (incl. the sparse-height/Instagram case), duration-based download timeout, filename sanitization, SQLite download-record lifecycle, `GET /api/jobs*` handlers | [README](https://github.com/RomanGhost/vdownloader_worker/blob/main/README.md#testing) |
  | `vdownloader_telegram` | Config loading, inline-keyboard builders, file delivery helpers, worker HTTP client (against `httptest`) | [README](https://github.com/RomanGhost/vdownloader_telegram/blob/main/README.md#testing) |
  | `vdownloader_web` | Config loading, `POST /api/jobs` validation/publish logic (against an in-memory fake publisher) | [README](https://github.com/RomanGhost/vdownloader_web/blob/master/README.md#testing) |

  None of these touch `yt-dlp`/`ffmpeg`/a real RabbitMQ broker/Telegram — anything that shells out or needs a live service is covered by the smoke test below instead.

- **End-to-end smoke test** ([scripts/smoke-test.sh](scripts/smoke-test.sh)): run against a freshly started stack (local `docker compose up` or a real server) before relying on it. Submits a real job through the full path — web → RabbitMQ → worker → yt-dlp → file — and checks the job reaches `ready`, the file downloads, and its video codec is actually H.264. This is the check that would have caught most bugs found in this project so far: output filename collisions between concurrent jobs, the codec not actually being transcoded, and playlist URLs being downloaded in full. It does *not* exercise the Telegram bot's own flow (no automated way to drive a real Telegram chat) — check that manually before deploying a change to `vdownloader_telegram`.

  ```bash
  ./scripts/smoke-test.sh
  # or against a remote deployment:
  WEB_URL=http://myserver:8082 WORKER_URL=http://myserver:8080 ./scripts/smoke-test.sh
  ```

## Known limitations

- `vdownloader_web`'s job-status polling ([static/app.js](https://github.com/RomanGhost/vdownloader_web/blob/master/static/app.js), a separate repo) treats the first `404` after submitting a job as a hard error rather than an expected transient state (the worker's consumer needs a brief moment to persist the record after the job is published) — it still recovers on the next poll 2s later, but the UI briefly flashes a red error message on every submission.
- Sources whose maximum resolution is below 360p (old/archival videos) have no selectable video tier at all — only "Audio only" — since the standardized ladder's smallest rung is 360p.
