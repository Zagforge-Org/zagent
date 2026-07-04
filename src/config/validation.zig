//! Validation for validating `zagent.config.json` JSON represented data.
//! This file specifies validation rules and errors used across for the
//! configuration.

const std = @import("std");
const Config = @import("config.zig").Config;

// Sanity ceilings: type-valid values above these would overflow downstream
// casts/shifts/allocations (u64->i64 duration casts, the backoff `<<`, the ring
// allocation), so reject them up front. Tune as needed.
const max_line_bytes_max = 64 * 1024 * 1024; // 64 MiB per line
const interval_ms_max = 24 * 60 * 60 * 1000; // 24h; well within i64 ms
const buffer_capacity_max = 10_000_000; // records
const max_retries_max = 20; // backoff shifts by `attempt`; keep < 63

pub const ValidationError = error{
    EmptyEndpoint,
    EndpointMissingScheme,
    InsecureEndpoint,
    EmptyLogPaths,
    EmptyDiskPath,
    EmptyAuthHeader,
    ZeroMaxLineBytes,
    ZeroMetricInterval,
    ZeroBufferCapacity,
    ZeroBatchMax,
    ZeroSpoolMaxBytes,
    BatchMaxExceedsCapacity,
    SpoolMaxBytesTooSmall,
    MaxLineBytesTooLarge,
    MetricIntervalTooLarge,
    BufferCapacityTooLarge,
    TooManyRetries,
};

/// Semantic validation — the value-level rules the type system and JSON parser
/// can't enforce: non-empty strings, `> 0` numbers, cross-field constraints, and
/// upper bounds that keep downstream casts/shifts/allocations from overflowing.
pub fn validate(cfg: Config) ValidationError!void {
    // Required fields

    if (cfg.log_paths) |log_paths| {
        if (log_paths.len == 0) return error.EmptyLogPaths;
    }

    if (cfg.disk_path.len == 0) return error.EmptyDiskPath;

    // Endpoint
    if (cfg.endpoint) |endpoint| {
        if (endpoint.len == 0) return error.EmptyEndpoint;

        if (!std.mem.startsWith(u8, endpoint, "http://") and
            !std.mem.startsWith(u8, endpoint, "https://"))
            return error.EndpointMissingScheme;

        if (std.mem.startsWith(u8, endpoint, "http://") and !cfg.allow_insecure_http)
            return error.InsecureEndpoint;
    }

    // Positive values
    if (cfg.max_line_bytes == 0) return error.ZeroMaxLineBytes;
    if (cfg.metric_interval_ms == 0) return error.ZeroMetricInterval;
    if (cfg.buffer_capacity == 0) return error.ZeroBufferCapacity;
    if (cfg.batch_max == 0) return error.ZeroBatchMax;
    if (cfg.spool_max_bytes == 0) return error.ZeroSpoolMaxBytes;

    // Cross-field
    if (cfg.batch_max > cfg.buffer_capacity)
        return error.BatchMaxExceedsCapacity;

    // Optional values
    if (cfg.auth_header) |h|
        if (h.len == 0)
            return error.EmptyAuthHeader;

    // Upper bounds
    if (cfg.max_line_bytes > max_line_bytes_max)
        return error.MaxLineBytesTooLarge;
    if (cfg.metric_interval_ms > interval_ms_max)
        return error.MetricIntervalTooLarge;
    if (cfg.buffer_capacity > buffer_capacity_max)
        return error.BufferCapacityTooLarge;
    if (cfg.max_retries > max_retries_max)
        return error.TooManyRetries;

    // Relational, checked last where the spool
    // must be able to hold at least one max-size record.
    if (cfg.spool_max_bytes < cfg.max_line_bytes)
        return error.SpoolMaxBytesTooSmall;
}
