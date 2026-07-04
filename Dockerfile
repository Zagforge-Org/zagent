# syntax=docker/dockerfile:1

# ---- build stage --------------------------------------------------------------
# Pin the Zig version to build.zig.zon's minimum_zig_version. Verify the exact
# tarball name for your version at https://ziglang.org/download/ and override
# ZIG_TARBALL if it differs (naming has changed across releases).
ARG ZIG_VERSION=0.16.0
FROM debian:bookworm-slim AS build
ARG ZIG_VERSION
ARG ZIG_TARBALL=zig-x86_64-linux-${ZIG_VERSION}

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/${ZIG_TARBALL}.tar.xz" -o /tmp/zig.tar.xz \
    && mkdir -p /opt/zig \
    && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
    && ln -s /opt/zig/zig /usr/local/bin/zig

WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src
# ReleaseSafe keeps overflow/bounds checks, which matter for a durability-critical
# shipper (CRC framing, fsync ordering) and cost nothing on an fsync-bound path.
RUN zig build -Doptimize=ReleaseSafe

# ---- runtime stage ------------------------------------------------------------
FROM debian:bookworm-slim AS runtime

# ca-certificates is REQUIRED, not optional: the HTTPS exporter verifies the
# server certificate against the system trust store and fails closed without it.
# tini forwards SIGTERM so the graceful drain runs; procps backs the healthcheck.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates tini procps \
    && rm -rf /var/lib/apt/lists/*

# Non-root service user with a writable HOME. The durable spool lives under
# $HOME/.zagent and MUST persist across restarts for at-least-once delivery.
RUN useradd --system --create-home --home-dir /var/lib/zagent --shell /usr/sbin/nologin zagent

COPY --from=build /src/zig-out/bin/zagent /usr/local/bin/zagent

USER zagent
ENV HOME=/var/lib/zagent
WORKDIR /var/lib/zagent

# Persist the spool + checkpoints. Losing this volume re-ships or drops in-flight
# records depending on timing; keeping it is what makes delivery at-least-once.
VOLUME ["/var/lib/zagent"]

# Liveness only: confirms the process exists, NOT that it is still shipping. A
# wedged-but-alive process is not detected here; see DEPLOY.md (health section).
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD pgrep -x zagent >/dev/null || exit 1

# Config is mounted at /etc/zagent/zagent.config.json (see DEPLOY.md). tini reaps
# and forwards signals so SIGTERM reaches zagent and triggers the graceful drain.
ENTRYPOINT ["tini", "--", "zagent", "-c", "/etc/zagent/zagent.config.json"]
