# Changelog

All notable changes to zagent are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-07-04

The production-hardening release: security, durability, observability, and
deployment. No breaking changes to the config or CLI surface.

### Added
- HTTPS is enforced at the config boundary. Plaintext `http://` endpoints are
  rejected unless `allow_insecure_http: true` is set explicitly.
- Loss observability. A shared atomic `Counters` (`spool_dropped`,
  `batches_shipped`, `send_failures`) is folded into each telemetry sample under
  a `zagent` block, plus a rate-limited local "loss report" heartbeat and a
  shutdown summary from the exporter — so loss is visible even while the endpoint
  is down and telemetry can't ship.
- Load/soak harness: `zig build load -- [seconds]` drives the real pipeline and
  reports RSS, open fds, and spool size to show they stay bounded under load.
- Deployment: multi-stage `Dockerfile` (non-root, bundles `ca-certificates` and
  `tini`, ReleaseSafe), a hardened `deploy/zagent.service` systemd unit, and
  `DEPLOY.md`.
- CI (build + test + format check) and release (binaries + GitHub Release +
  GHCR image) GitHub Actions workflows, and this changelog.

### Changed
- Checkpoints are now power-loss durable: `state.writeAtomic` fsyncs the
  directory after the rename, so the spool cursor and tailer offset survive a
  power cut instead of reverting.
- Graceful shutdown: the exporter drains the ring to the durable spool on stop,
  and a dedicated exporter stop-flag orders that final drain after the sampler
  has quiesced — closing a race that could strand the last metric sample.
- `wire.toJsonLine` sanitizes invalid UTF-8 to U+FFFD, so the `msg` field is
  always a JSON string instead of silently degrading to a byte array.
- `json.Deserialize` uses `.alloc_always`, so parsed values never alias the
  input buffer.
- The `batches_failed` counter was renamed to `send_failures` to distinguish
  retry-exhausted attempts (data retained) from real loss.
- Source layout: CLI parsing moved under `cli/`, and `Counters`, `Spool`, and
  `wire` moved under `core/`.

### Fixed
- The end-to-end integration test no longer uses a hardcoded port or a fixed
  sleep; it binds an ephemeral port and polls for delivery, removing CI flake.

### Security
- Confirmed the HTTPS exporter verifies the server certificate chain and
  hostname against the system trust store by default, and fails closed when the
  trust store is absent.

---

Releases prior to 0.2.0 predate this changelog and are captured only in the git
history.

[Unreleased]: https://github.com/Zagforge-Org/zagent/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/Zagforge-Org/zagent/releases/tag/v0.2.0
