// Migrated unit tests for src/server/tls.zig.

const std = @import("std");
const TlsContext = @import("../../../src/server/tls.zig").TlsContext;

test "tls module compiles" {
    // Just verify the module compiles without OpenSSL linked.
    // Actual TLS tests require cert/key files.
    const t: ?TlsContext = null;
    _ = t;
}
