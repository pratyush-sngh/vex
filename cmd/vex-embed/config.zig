//! vex-embed configuration: CLI flag parsing.
//!
//! Every field has a sane default so `vex-embed` with no args proxies
//! 127.0.0.1:6390 → 127.0.0.1:6380 and embeds against a local Ollama.
//!
//! Flags (all optional):
//!   --listen-port    <u16>          port the proxy accepts clients on   (6390)
//!   --vex-host       <str>          upstream vex host                   (127.0.0.1)
//!   --vex-port       <u16>          upstream vex port                   (6380)
//!   --embed-url      <str>          embedding HTTP endpoint
//!   --embed-model    <str>          model name sent in the request body
//!   --embed-key      <str>          bearer token (OpenAI-compatible)    (none)
//!   --embed-provider <ollama|openai>                                    (ollama)
//!   --log-level      <str>          debug|info|warn|error               (info)

const std = @import("std");
const vex_log = @import("vex_log");

pub const Provider = enum {
    ollama,
    openai,

    pub fn parse(s: []const u8) ?Provider {
        if (std.mem.eql(u8, s, "ollama")) return .ollama;
        if (std.mem.eql(u8, s, "openai")) return .openai;
        return null;
    }
};

pub const Config = struct {
    listen_port: u16 = 6390,
    vex_host: []const u8 = "127.0.0.1",
    vex_port: u16 = 6380,
    embed_url: []const u8 = "http://localhost:11434/api/embeddings",
    embed_model: []const u8 = "nomic-embed-text",
    /// Bearer token for OpenAI-compatible endpoints. Empty = no auth header.
    embed_key: []const u8 = "",
    provider: Provider = .ollama,
    log_level: vex_log.Level = .info,
    /// When true, rewrite allowlisted commands carrying a `TEXT "<string>"`
    /// marker: embed the string inline and substitute raw f32 bytes before
    /// forwarding to vex. Off = the proxy stays byte-transparent (EMBED only).
    auto_rewrite: bool = false,
};

/// Parse argv into a Config. Unknown flags are ignored (forward-compatible);
/// flags with an unparseable value keep their default and emit nothing here —
/// callers log the resolved config so a typo is visible at startup.
pub fn parseArgs(init: std.process.Init) Config {
    var out = Config{};
    var it = std.process.Args.Iterator.init(init.minimal.args);
    defer it.deinit();
    _ = it.skip(); // argv[0]

    while (it.next()) |arg_z| {
        const arg = std.mem.sliceTo(arg_z, 0);
        if (std.mem.eql(u8, arg, "--listen-port")) {
            if (nextVal(&it)) |v| out.listen_port = std.fmt.parseInt(u16, v, 10) catch out.listen_port;
        } else if (std.mem.eql(u8, arg, "--vex-host")) {
            if (nextVal(&it)) |v| out.vex_host = v;
        } else if (std.mem.eql(u8, arg, "--vex-port")) {
            if (nextVal(&it)) |v| out.vex_port = std.fmt.parseInt(u16, v, 10) catch out.vex_port;
        } else if (std.mem.eql(u8, arg, "--embed-url")) {
            if (nextVal(&it)) |v| out.embed_url = v;
        } else if (std.mem.eql(u8, arg, "--embed-model")) {
            if (nextVal(&it)) |v| out.embed_model = v;
        } else if (std.mem.eql(u8, arg, "--embed-key")) {
            if (nextVal(&it)) |v| out.embed_key = v;
        } else if (std.mem.eql(u8, arg, "--embed-provider")) {
            if (nextVal(&it)) |v| out.provider = Provider.parse(v) orelse out.provider;
        } else if (std.mem.eql(u8, arg, "--log-level")) {
            if (nextVal(&it)) |v| out.log_level = vex_log.Level.parse(v);
        } else if (std.mem.eql(u8, arg, "--auto-rewrite")) {
            out.auto_rewrite = true;
        }
    }
    return out;
}

fn nextVal(it: *std.process.Args.Iterator) ?[]const u8 {
    return if (it.next()) |v| std.mem.sliceTo(v, 0) else null;
}
