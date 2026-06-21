const std = @import("std");
const testing = std.testing;

const Config = @import("config.zig").Config;
const validation = @import("validation.zig");

// A baseline config that passes validation. Tests clone it and break one field
// so each assertion isolates a single rule. Fields not set here use the struct
// defaults (which are all within bounds).
fn validCfg() Config {
    return .{
        .log_paths = "logs/app.log",
        .disk_path = "/",
        .endpoint = "http://localhost:8080/ingest",
    };
}

test "a well-formed config passes" {
    try validation.validate(validCfg());
}

// ── endpoint ────────────────────────────────────────────────────────────────

test "endpoint: empty string is rejected" {
    var c = validCfg();
    c.endpoint = "";
    try testing.expectError(error.EmptyEndpoint, validation.validate(c));
}

test "endpoint: missing http(s) scheme is rejected" {
    var c = validCfg();
    c.endpoint = "localhost:8080/ingest";
    try testing.expectError(error.EndpointMissingScheme, validation.validate(c));
}

test "endpoint: https scheme is accepted" {
    var c = validCfg();
    c.endpoint = "https://example.com/ingest";
    try validation.validate(c);
}

// ── strings ─────────────────────────────────────────────────────────────────

test "log_paths: empty string is rejected" {
    var c = validCfg();
    c.log_paths = "";
    try testing.expectError(error.EmptyLogPaths, validation.validate(c));
}

test "disk_path: empty string is rejected" {
    var c = validCfg();
    c.disk_path = "";
    try testing.expectError(error.EmptyDiskPath, validation.validate(c));
}

test "auth_header: present but empty is rejected" {
    var c = validCfg();
    c.auth_header = "";
    try testing.expectError(error.EmptyAuthHeader, validation.validate(c));
}

test "auth_header: present and non-empty is accepted" {
    var c = validCfg();
    c.auth_header = "Bearer token";
    try validation.validate(c);
}

// ── must be > 0 ─────────────────────────────────────────────────────────────

test "zero max_line_bytes is rejected" {
    var c = validCfg();
    c.max_line_bytes = 0;
    try testing.expectError(error.ZeroMaxLineBytes, validation.validate(c));
}

test "zero metric_interval_ms is rejected" {
    var c = validCfg();
    c.metric_interval_ms = 0;
    try testing.expectError(error.ZeroMetricInterval, validation.validate(c));
}

test "zero buffer_capacity is rejected" {
    var c = validCfg();
    c.buffer_capacity = 0;
    try testing.expectError(error.ZeroBufferCapacity, validation.validate(c));
}

test "zero batch_max is rejected" {
    var c = validCfg();
    c.batch_max = 0;
    try testing.expectError(error.ZeroBatchMax, validation.validate(c));
}

// ── cross-field ─────────────────────────────────────────────────────────────

test "batch_max larger than buffer_capacity is rejected" {
    var c = validCfg();
    c.buffer_capacity = 100;
    c.batch_max = 200;
    try testing.expectError(error.BatchMaxExceedsCapacity, validation.validate(c));
}

// ── upper bounds (overflow guards) ──────────────────────────────────────────
// Values are chosen just past the ceilings in validation.zig; if you retune a
// ceiling, the matching value here must move with it.

test "max_line_bytes above the ceiling is rejected" {
    var c = validCfg();
    c.max_line_bytes = 128 * 1024 * 1024; // > 64 MiB
    try testing.expectError(error.MaxLineBytesTooLarge, validation.validate(c));
}

test "metric_interval_ms above the ceiling is rejected" {
    var c = validCfg();
    c.metric_interval_ms = 48 * 60 * 60 * 1000; // > 24h
    try testing.expectError(error.MetricIntervalTooLarge, validation.validate(c));
}

test "batch_ms above the ceiling is rejected" {
    var c = validCfg();
    c.batch_ms = 48 * 60 * 60 * 1000; // > 24h
    try testing.expectError(error.BatchMsTooLarge, validation.validate(c));
}

test "buffer_capacity above the ceiling is rejected" {
    var c = validCfg();
    c.buffer_capacity = 20_000_000; // > 10M
    try testing.expectError(error.BufferCapacityTooLarge, validation.validate(c));
}

test "max_retries above the ceiling is rejected" {
    var c = validCfg();
    c.max_retries = 64; // > 20 (and would overflow the backoff shift)
    try testing.expectError(error.TooManyRetries, validation.validate(c));
}
