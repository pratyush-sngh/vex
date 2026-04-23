const std = @import("std");

// ── OpenSSL opaque types ────────────────────────────────────────────
pub const SSL_CTX = opaque {};
pub const SSL = opaque {};
pub const SSL_METHOD = opaque {};

const SSL_FILETYPE_PEM: c_int = 1;
pub const SSL_ERROR_WANT_READ: c_int = 2;
pub const SSL_ERROR_WANT_WRITE: c_int = 3;

// ── Function pointer types (loaded via dlopen) ──────────────────────
const FnTLSServerMethod = *const fn () callconv(.c) ?*const SSL_METHOD;
const FnSSLCTXNew = *const fn (?*const SSL_METHOD) callconv(.c) ?*SSL_CTX;
const FnSSLCTXFree = *const fn (*SSL_CTX) callconv(.c) void;
const FnSSLCTXUseCertFile = *const fn (*SSL_CTX, [*:0]const u8, c_int) callconv(.c) c_int;
const FnSSLCTXUseKeyFile = *const fn (*SSL_CTX, [*:0]const u8, c_int) callconv(.c) c_int;
const FnSSLCTXCheckKey = *const fn (*const SSL_CTX) callconv(.c) c_int;
const FnSSLNew = *const fn (*SSL_CTX) callconv(.c) ?*SSL;
const FnSSLFree = *const fn (*SSL) callconv(.c) void;
const FnSSLSetFd = *const fn (*SSL, c_int) callconv(.c) c_int;
const FnSSLAccept = *const fn (*SSL) callconv(.c) c_int;
const FnSSLRead = *const fn (*SSL, [*]u8, c_int) callconv(.c) c_int;
const FnSSLWrite = *const fn (*SSL, [*]const u8, c_int) callconv(.c) c_int;
const FnSSLGetError = *const fn (*const SSL, c_int) callconv(.c) c_int;
const FnSSLShutdown = *const fn (*SSL) callconv(.c) c_int;

// ── TLS context (wraps OpenSSL loaded at runtime) ───────────────────

pub const TlsContext = struct {
    ctx: *SSL_CTX,
    lib_ssl: *anyopaque,
    lib_crypto: *anyopaque,

    // Cached function pointers
    ssl_new: FnSSLNew,
    ssl_free: FnSSLFree,
    ssl_set_fd: FnSSLSetFd,
    ssl_accept: FnSSLAccept,
    ssl_read: FnSSLRead,
    ssl_write: FnSSLWrite,
    ssl_get_error: FnSSLGetError,
    ssl_shutdown: FnSSLShutdown,
    ssl_ctx_free: FnSSLCTXFree,

    pub fn init(cert_path: [*:0]const u8, key_path: [*:0]const u8) !TlsContext {
        // Load OpenSSL libraries at runtime (no build-time dependency)
        const lib_crypto = loadLib("libcrypto") orelse return error.TlsNotAvailable;
        const lib_ssl = loadLib("libssl") orelse {
            _ = std.c.dlclose(lib_crypto);
            return error.TlsNotAvailable;
        };

        const tls_server_method = loadSym(FnTLSServerMethod, lib_ssl, "TLS_server_method") orelse
            return error.TlsNotAvailable;
        const ssl_ctx_new = loadSym(FnSSLCTXNew, lib_ssl, "SSL_CTX_new") orelse
            return error.TlsNotAvailable;
        const ssl_ctx_free = loadSym(FnSSLCTXFree, lib_ssl, "SSL_CTX_free") orelse
            return error.TlsNotAvailable;
        const ssl_ctx_use_cert = loadSym(FnSSLCTXUseCertFile, lib_ssl, "SSL_CTX_use_certificate_file") orelse
            return error.TlsNotAvailable;
        const ssl_ctx_use_key = loadSym(FnSSLCTXUseKeyFile, lib_ssl, "SSL_CTX_use_PrivateKey_file") orelse
            return error.TlsNotAvailable;
        const ssl_ctx_check_key = loadSym(FnSSLCTXCheckKey, lib_ssl, "SSL_CTX_check_private_key") orelse
            return error.TlsNotAvailable;

        const method = tls_server_method() orelse return error.TlsInitFailed;
        const ctx = ssl_ctx_new(method) orelse return error.TlsInitFailed;

        if (ssl_ctx_use_cert(ctx, cert_path, SSL_FILETYPE_PEM) != 1) {
            ssl_ctx_free(ctx);
            return error.TlsCertLoadFailed;
        }
        if (ssl_ctx_use_key(ctx, key_path, SSL_FILETYPE_PEM) != 1) {
            ssl_ctx_free(ctx);
            return error.TlsKeyLoadFailed;
        }
        if (ssl_ctx_check_key(ctx) != 1) {
            ssl_ctx_free(ctx);
            return error.TlsKeyMismatch;
        }

        return .{
            .ctx = ctx,
            .lib_ssl = lib_ssl,
            .lib_crypto = lib_crypto,
            .ssl_new = loadSym(FnSSLNew, lib_ssl, "SSL_new") orelse return error.TlsNotAvailable,
            .ssl_free = loadSym(FnSSLFree, lib_ssl, "SSL_free") orelse return error.TlsNotAvailable,
            .ssl_set_fd = loadSym(FnSSLSetFd, lib_ssl, "SSL_set_fd") orelse return error.TlsNotAvailable,
            .ssl_accept = loadSym(FnSSLAccept, lib_ssl, "SSL_accept") orelse return error.TlsNotAvailable,
            .ssl_read = loadSym(FnSSLRead, lib_ssl, "SSL_read") orelse return error.TlsNotAvailable,
            .ssl_write = loadSym(FnSSLWrite, lib_ssl, "SSL_write") orelse return error.TlsNotAvailable,
            .ssl_get_error = loadSym(FnSSLGetError, lib_ssl, "SSL_get_error") orelse return error.TlsNotAvailable,
            .ssl_shutdown = loadSym(FnSSLShutdown, lib_ssl, "SSL_shutdown") orelse return error.TlsNotAvailable,
            .ssl_ctx_free = ssl_ctx_free,
        };
    }

    pub fn deinit(self: *TlsContext) void {
        self.ssl_ctx_free(self.ctx);
        _ = std.c.dlclose(self.lib_ssl);
        _ = std.c.dlclose(self.lib_crypto);
    }

    /// Create an SSL object for a new connection and run the handshake.
    /// Returns null if the handshake fails (caller should close the fd).
    pub fn wrapFd(self: *TlsContext, fd: i32) ?*SSL {
        const ssl = self.ssl_new(self.ctx) orelse return null;
        _ = self.ssl_set_fd(ssl, fd);

        // Set socket to blocking for the handshake, then back to non-blocking.
        const flags = std.c.fcntl(fd, std.c.F.GETFL);
        _ = std.c.fcntl(fd, std.c.F.SETFL, flags & ~@as(c_int, @bitCast(std.c.O{ .NONBLOCK = true })));
        const rc = self.ssl_accept(ssl);
        _ = std.c.fcntl(fd, std.c.F.SETFL, flags); // restore

        if (rc != 1) {
            self.ssl_free(ssl);
            return null;
        }
        return ssl;
    }

    pub fn sslRead(self: *TlsContext, ssl: *SSL, buf: [*]u8, len: usize) isize {
        const n: c_int = @intCast(@min(len, std.math.maxInt(c_int)));
        const rc = self.ssl_read(ssl, buf, n);
        if (rc <= 0) {
            const err = self.ssl_get_error(ssl, rc);
            if (err == SSL_ERROR_WANT_READ or err == SSL_ERROR_WANT_WRITE) return -1; // EAGAIN equivalent
            return 0; // connection closed or fatal error
        }
        return @intCast(rc);
    }

    pub fn sslWrite(self: *TlsContext, ssl: *SSL, buf: [*]const u8, len: usize) isize {
        const n: c_int = @intCast(@min(len, std.math.maxInt(c_int)));
        const rc = self.ssl_write(ssl, buf, n);
        if (rc <= 0) {
            const err = self.ssl_get_error(ssl, rc);
            if (err == SSL_ERROR_WANT_WRITE or err == SSL_ERROR_WANT_READ) return -1; // EAGAIN
            return 0; // closed or fatal
        }
        return @intCast(rc);
    }

    pub fn sslClose(self: *TlsContext, ssl: *SSL) void {
        _ = self.ssl_shutdown(ssl);
        self.ssl_free(ssl);
    }
};

// ── dlopen helpers ──────────────────────────────────────────────────

fn loadLib(name: [*:0]const u8) ?*anyopaque {
    // Try platform-specific names
    const suffixes = switch (@import("builtin").os.tag) {
        .macos => &[_][*:0]const u8{ ".3.dylib", ".dylib" },
        else => &[_][*:0]const u8{ ".so.3", ".so" },
    };
    for (suffixes) |suffix| {
        var buf: [256]u8 = undefined;
        const full = std.fmt.bufPrintZ(&buf, "lib{s}{s}", .{ std.mem.span(name), std.mem.span(suffix) }) catch continue;
        if (std.c.dlopen(full, 2)) |handle| return handle; // RTLD_NOW = 2
    }
    // Try bare name
    if (std.c.dlopen(name, 2)) |handle| return handle;
    return null;
}

fn loadSym(comptime T: type, handle: *anyopaque, name: [*:0]const u8) ?T {
    const ptr = std.c.dlsym(handle, name) orelse return null;
    return @ptrCast(ptr);
}

// ── Tests ───────────────────────────────────────────────────────────

test "tls module compiles" {
    // Just verify the module compiles without OpenSSL linked.
    // Actual TLS tests require cert/key files.
    const t: ?TlsContext = null;
    _ = t;
}
