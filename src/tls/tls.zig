const std = @import("std");
const posix = std.posix;
const ssl = @import("ssl.zig");

pub const SslContext = ssl.SslContext;
pub const SslConnection = ssl.SslConnection;
pub const SslError = ssl.SslError;
pub const getLastError = ssl.getLastError;

/// TLS Configuration
pub const TlsConfig = struct {
    cert_path: []const u8,
    key_path: []const u8,
    /// Optional: CA certificate for client verification
    ca_path: ?[]const u8 = null,
    /// Minimum TLS version (default: TLS 1.2)
    min_version: TlsVersion = .tls_1_2,
};

pub const TlsVersion = enum {
    tls_1_2,
    tls_1_3,
};

/// TLS Server - manages SSL context and connections
pub const TlsServer = struct {
    ctx: SslContext,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: TlsConfig) !TlsServer {
        var ctx = try SslContext.init();
        errdefer ctx.deinit();

        // Convert paths to null-terminated strings
        const cert_z = try allocator.dupeZ(u8, config.cert_path);
        defer allocator.free(cert_z);

        const key_z = try allocator.dupeZ(u8, config.key_path);
        defer allocator.free(key_z);

        try ctx.loadCertificate(cert_z.ptr);
        try ctx.loadPrivateKey(key_z.ptr);

        return .{
            .ctx = ctx,
            .allocator = allocator,
        };
    }

    /// Wrap an accepted socket with TLS
    pub fn wrapConnection(self: *TlsServer, fd: posix.fd_t) !SslConnection {
        var conn = try SslConnection.init(&self.ctx, fd);
        errdefer conn.deinit();

        // Perform TLS handshake
        try conn.accept();

        return conn;
    }

    pub fn deinit(self: *TlsServer) void {
        self.ctx.deinit();
    }
};

/// TLS-enabled connection that wraps Spark's Connection
pub const TlsConnection = struct {
    ssl_conn: SslConnection,
    fd: posix.fd_t,

    pub fn read(self: *TlsConnection, buf: []u8) !usize {
        return self.ssl_conn.read(buf);
    }

    pub fn write(self: *TlsConnection, data: []const u8) !usize {
        return self.ssl_conn.write(data);
    }

    pub fn close(self: *TlsConnection) void {
        self.ssl_conn.shutdown();
        self.ssl_conn.deinit();
        posix.close(self.fd);
    }
};

test "tls module compiles" {
    // Just verify the module compiles
    _ = SslContext;
    _ = TlsServer;
}
