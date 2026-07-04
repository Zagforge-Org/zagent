<p align="center">
  <img src="assets/logo.png" alt="zagent logo" width="140" height="140">
</p>

<h1 align="center">zagent</h1>

<p align="center">
  <a href="https://github.com/Zagforge-Org/zagent/actions/workflows/ci.yml">
    <img src="https://github.com/Zagforge-Org/zagent/actions/workflows/ci.yml/badge.svg" alt="CI">
  </a>
  <a href="https://github.com/Zagforge-Org/zagent/releases/latest">
    <img src="https://img.shields.io/github/v/release/Zagforge-Org/zagent?label=release" alt="Latest release">
  </a>
</p>

A small, durable log + metric shipper. `zagent` tails a growing log file,
samples host metrics on an interval, and ships them to an HTTPS ingest endpoint
as gzipped NDJSON — with **at-least-once delivery** that survives crashes and
outages.

Written in [Zig](https://ziglang.org) (0.16.0), Linux-only, single static binary,
no runtime dependencies beyond the system CA store.

## How it works

Two producers feed a durable on-disk spool; one consumer ships from it.

```
  log file  ──▶  Tailer  ──────────────▶  ┐
             (complete lines, offset      │
              checkpointed on disk)       ├──▶  Spool  ──▶  Exporter  ──▶  HTTPS ingest
                                          │   (durable,     (gzip NDJSON     (retries with
  /proc +   ──▶  Sampler ──▶ RingBuffer ──┘    CRC-framed,   batches)         backoff; commits
  statfs        (metric      (in-memory,        fsync'd)                       the cursor on 2xx)
                 samples)     bounded)
```

- **Tailer** follows the file like `tail -F`: survives rotation (by inode) and
  in-place truncation, buffers partial lines, and writes complete lines straight
  to the durable spool, checkpointing its read offset.
- **Sampler** reads `/proc` (CPU, memory, uptime) and `statfs` (disk) on an
  interval and pushes metric records into an in-memory ring buffer.
- **Exporter** drains the ring onto the spool, builds NDJSON batches from the
  spool, gzips and POSTs them, and commits the spool cursor only after a `2xx`.
  A permanent failure rewinds the cursor so the batch is retried and survives a
  restart.
- **Loss counters** (`spool_dropped`, `batches_shipped`, `send_failures`) are
  folded into every metric sample and surfaced via a local heartbeat, so loss is
  visible even while the endpoint is unreachable.

### Delivery guarantees

Delivery is **at-least-once**: a crash or power cut between shipping and the
cursor commit re-sends the last batch. **Downstream must tolerate duplicates.**
The spool is CRC-framed and fsync'd per record, and checkpoints are directory-
fsync'd, so records are durable across process crashes and power loss.

## Install

### Prebuilt binary (recommended)

Static Linux binaries are attached to each
[release](https://github.com/Zagforge-Org/zagent/releases/latest):

```sh
ver=v0.2.0                        # latest release tag
arch=x86_64-linux                 # or aarch64-linux
curl -fsSL "https://github.com/Zagforge-Org/zagent/releases/download/${ver}/zagent-${ver}-${arch}.tar.gz" | tar -xz
./zagent-${ver}-${arch}/zagent --version
```

### Container image

```sh
docker pull ghcr.io/zagforge-org/zagent:0.2.0   # or :latest
```

See [DEPLOY.md](DEPLOY.md) for running it (config, volumes, `ca-certificates`).

### From source

```sh
zig build -Doptimize=ReleaseSafe   # binary at zig-out/bin/zagent
```

`ReleaseSafe` keeps the overflow/bounds checks that guard the CRC framing and
fsync ordering; the pipeline is fsync-bound, so the checks cost nothing
measurable.

## Quick start

```sh
zagent --init                 # write a default zagent.config.json
$EDITOR zagent.config.json    # set log_paths and an https:// endpoint
zagent --check                # validate the config
zagent                        # run the pipeline (Ctrl-C / SIGTERM to stop)
```

## Configuration

Config is a JSON file (default `zagent.config.json`, override with `-c PATH`).
`log_paths` and `endpoint` are required to run; everything else has a default.

| Field                 | Type    | Default        | Description                                             |
| --------------------- | ------- | -------------- | ------------------------------------------------------- |
| `log_paths`           | string  | —              | Log file to tail (required to run).                     |
| `endpoint`            | string  | —              | Ingest URL (required to run). Must be `https://` …      |
| `allow_insecure_http` | bool    | `false`        | … unless this is `true`, which permits `http://`.       |
| `auth_header`         | string? | `null`         | `Authorization` header value (e.g. `Bearer …`).         |
| `max_line_bytes`      | int     | `65536`        | Max line length; longer lines are dropped.              |
| `metric_interval_ms`  | int     | `10000`        | Sampler tick interval.                                  |
| `disk_path`           | string  | `/`            | Mount point to report disk usage for.                   |
| `buffer_capacity`     | int     | `10000`        | Ring buffer size, in records.                           |
| `backpressure`        | enum    | `drop_oldest`  | `drop_oldest` \| `drop_newest` \| `block`.              |
| `spool_max_bytes`     | int     | `67108864`     | On-disk durable queue cap (64 MiB).                     |
| `batch_max`           | int     | `100`          | Max records shipped per request.                        |
| `max_retries`         | int     | `5`            | Send retries before giving up a batch attempt.          |

The durable spool and checkpoints live under `$HOME/.zagent` and **must persist
across restarts** — that directory is what makes delivery at-least-once.

## CLI

```
zagent [-c PATH]           run the pipeline (default)
zagent --init              write a default zagent.config.json
zagent --check [-c PATH]   validate the config and exit
zagent --version           print the version
zagent --help              print usage

-c, --config PATH          config file (default: zagent.config.json)
```

`SIGTERM`/`SIGINT` triggers a graceful drain: producers stop, the exporter
flushes the in-memory ring to the durable spool, then the process exits.

## Deployment

See [DEPLOY.md](DEPLOY.md) for container and systemd setup, including the
required `ca-certificates` dependency (HTTPS fails closed without it) and the
operational invariants.

## Development

```sh
zig build test              # run the unit + integration tests
zig fmt --check src build.zig
zig build load -- 30        # load/soak harness: 30s, reports RSS/fd/spool bounds
```

CI runs the format check, build, and tests on every push and PR
(`.github/workflows/ci.yml`). Tagging `v*` cuts a release: cross-compiled
binaries, a GitHub Release generated from the changelog, and a GHCR image
(`.github/workflows/release.yml`).

## Versioning

Semantic Versioning; see [CHANGELOG.md](CHANGELOG.md).

## License

No license file is present yet — add a `LICENSE` before public distribution.
