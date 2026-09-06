//! vex-embed: a transparent RESP proxy that adds text→vector embedding.
//!
//! vex deliberately does NOT compute embeddings — that would put blocking
//! HTTP calls on its microsecond-clean event loop. vex-embed is an optional
//! separate process that sits in front of vex: it forwards all RESP traffic
//! byte-for-byte, EXCEPT it intercepts one command, `EMBED <text>`, which it
//! turns into a vector by calling an external embedding endpoint (Ollama or
//! an OpenAI-compatible API) and replies with the raw little-endian f32
//! bytes. The client then feeds those bytes to vex's GRAPH.SETVEC / VECSEARCH.
//!
//! Run:
//!   vex-embed --embed-provider ollama \
//!             --embed-url http://localhost:11434/api/embeddings \
//!             --embed-model nomic-embed-text
//!
//! See docs/embedding.md for the full flag list and rationale. The
//! per-command auto-rewrite (CACHE.*/MEMORY.* embedding inline) is a future
//! step; see the TODO in embed/proxy.zig.

const std = @import("std");
const vex_log = @import("vex_log");
const config_mod = @import("config.zig");
const proxy_mod = @import("proxy.zig");

var g_stop = std.atomic.Value(bool).init(false);

fn installSignalHandlers() void {
    const c = std.c;
    var sa: c.Sigaction = undefined;
    @memset(@as([*]u8, @ptrCast(&sa))[0..@sizeOf(c.Sigaction)], 0);
    sa.handler = .{ .handler = @ptrCast(&struct {
        fn handler(_: c_int) callconv(.c) void {
            g_stop.store(true, .release);
        }
    }.handler) };
    _ = c.sigaction(c.SIG.INT, &sa, null);
    _ = c.sigaction(c.SIG.TERM, &sa, null);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const cfg = config_mod.parseArgs(init);

    vex_log.global = vex_log.Logger.initStderr(cfg.log_level, .text);
    vex_log.info("vex-embed starting: listen=:{d} vex={s}:{d} provider={s} model={s} url={s}", .{
        cfg.listen_port,
        cfg.vex_host,
        cfg.vex_port,
        @tagName(cfg.provider),
        cfg.embed_model,
        cfg.embed_url,
    });
    if (cfg.provider == .openai and cfg.embed_key.len == 0) {
        vex_log.warn("openai provider selected but --embed-key is empty; requests will be unauthenticated", .{});
    }

    var proxy = proxy_mod.Proxy.init(allocator, cfg);
    defer proxy.deinit();
    proxy.listen() catch |err| {
        vex_log.err("vex-embed: failed to bind :{d}: {s}", .{ cfg.listen_port, @errorName(err) });
        return err;
    };

    installSignalHandlers();

    // The accept loop runs on its own thread so the main thread can watch the
    // stop flag and tear the listener down on SIGINT/SIGTERM (which unblocks
    // accept() with EBADF).
    const t = try std.Thread.spawn(.{}, proxy_mod.Proxy.run, .{&proxy});
    while (!g_stop.load(.acquire)) sleepMs(200);

    vex_log.info("vex-embed shutting down", .{});
    proxy.deinit(); // closes listen_fd, unblocks accept
    t.join();
}

fn sleepMs(ms: u64) void {
    var ts: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * 1_000_000),
    };
    var rem: std.c.timespec = undefined;
    _ = std.c.nanosleep(&ts, &rem);
}

// Pull in unit tests from the sibling modules so `test-vex-embed` (which
// roots at this file) exercises them.
test {
    std.testing.refAllDecls(@This());
    _ = @import("config.zig");
    _ = @import("embedder.zig");
    _ = @import("proxy.zig");
    _ = @import("resp_detect.zig");
}
