# Deploying zagent

zagent tails a log file, samples host metrics, and ships gzipped NDJSON batches
to an HTTPS ingest endpoint with at-least-once delivery. This covers running it
in a container or under systemd, and the operational invariants that matter.

## Build

```sh
zig build -Doptimize=ReleaseSafe      # binary at zig-out/bin/zagent
```

ReleaseSafe is intentional: it keeps overflow/bounds checks that guard the CRC
framing and fsync ordering, and the pipeline is fsync-bound, not CPU-bound, so
the checks cost nothing measurable.

## Configuration

Generate a template and edit it:

```sh
zagent --init            # writes zagent.config.json
zagent --check -c PATH   # validate without running
```

Required to run: `log_paths` (the file to tail) and `endpoint`. The endpoint
**must be `https://`** unless you explicitly set `allow_insecure_http: true` —
plaintext is rejected by default.

## Operational invariants

These are not optional; getting them wrong silently breaks delivery.

1. **The spool must persist.** The durable queue and checkpoints live under
   `$HOME/.zagent`. That directory is what makes delivery at-least-once across
   crashes and outages — put it on a real volume, never a tmpfs. Losing it drops
   whatever hadn't shipped.

2. **ca-certificates must be present.** The exporter verifies the server
   certificate (chain + hostname) against the system trust store and **fails
   closed** if it is missing — HTTPS will error rather than fall back to
   insecure. The container image installs `ca-certificates`; on a bare host,
   ensure it is installed.

3. **Stop with SIGTERM.** SIGTERM (or SIGINT) triggers a graceful drain: the
   producers stop, the exporter flushes the in-memory ring to the durable spool,
   then exits. `SIGKILL` skips the drain and loses whatever was still in the
   volatile ring (best-effort metrics only; logs go straight to the spool).

4. **Downstream must tolerate duplicates.** At-least-once means a crash or a
   power cut between shipping and the cursor commit re-sends the last batch.

## Container

```sh
docker build -t zagent:0.2.0 .

docker run -d --name zagent \
  -v zagent-state:/var/lib/zagent \                 # durable spool (persist!)
  -v /path/to/app.log:/var/log/app.log:ro \         # the log to tail
  -v /path/to/zagent.config.json:/etc/zagent/zagent.config.json:ro \
  zagent:0.2.0
```

Point `log_paths` in the config at `/var/log/app.log` (the in-container path).
The image runs as a non-root user, bundles `tini` so SIGTERM reaches zagent, and
declares `/var/lib/zagent` as a volume.

Pin the Zig toolchain with `--build-arg ZIG_VERSION=…`; if the release tarball
name differs from `zig-x86_64-linux-<ver>`, override `--build-arg ZIG_TARBALL=…`.

## systemd

```sh
useradd --system --home-dir /var/lib/zagent --shell /usr/sbin/nologin zagent
install -D -m 0644 zagent.config.json /etc/zagent/zagent.config.json
cp deploy/zagent.service /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now zagent
```

`StateDirectory=zagent` gives the service a persistent, correctly-owned
`/var/lib/zagent` for the spool. The unit is hardened (read-only FS except the
spool, no new privileges, restricted address families) and restarts on failure.

## Health and observability — read this

**There is no health/readiness endpoint yet.** The container `HEALTHCHECK` and
systemd both provide *liveness* (process exists / exited), but neither detects a
process that is alive but wedged — e.g. shipping stalled while the spool fills.
Closing that gap needs a real health endpoint; it is tracked as a TODO.

What you *can* watch today:

- **Local logs.** The exporter emits a rate-limited `loss report` when
  `spool_dropped` / `send_failures` climb, and a summary line on shutdown. These
  surface loss even while the endpoint is down and telemetry can't ship.
- **Telemetry.** Each metric sample carries a `zagent` block —
  `ring_depth`, `spool_dropped`, `batches_shipped`, `send_failures`, etc. — so
  loss is visible downstream once delivery resumes.
- **Spool size.** A steadily growing `$HOME/.zagent/spool` toward its
  `spool_max_bytes` cap means the exporter is not keeping up (endpoint down or
  too slow). This is the signal a real healthcheck should watch.

## Capacity note

Durable-write throughput is bounded by fsync latency: the spool fsyncs every
record on append and fsyncs the directory on each checkpoint. On modest storage
that is roughly hundreds to low-thousands of records/sec. Size `buffer_capacity`
and `spool_max_bytes` for your burst volume, and expect the spool to absorb
bursts above the sustained fsync rate.
