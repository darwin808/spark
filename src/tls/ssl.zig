const std = @import("std");
const posix = std.posix;

/// OpenSSL C bindings
const c = @cImport({
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/err.h");
});

pub const SSL = c.SSL;
pub const SSL_CTX = c.SSL_CTX;

pub const SslError = error{
    InitFailed,
    ContextCreationFailed,
    CertificateLoadFailed,
    PrivateKeyLoadFailed,
    KeyMismatch,
    ConnectionFailed,
    HandshakeFailed,
    ReadFailed,
    WriteFailed,
    WouldBlock,
    Shutdown,
};

/// SSL Context - one per server, reused for all connections
pub const SslContext = struct {
    ctx: *SSL_CTX,

    pub fn init() SslError!SslContext {
        // Initialize OpenSSL (idempotent in newer versions)
        _ = c.OPENSSL_init_ssl(0, null);

        const method = c.TLS_server_method() orelse return SslError.InitFailed;
        const ctx = c.SSL_CTX_new(method) orelse return SslError.ContextCreationFailed;

        // Set reasonable defaults
        _ = c.SSL_CTX_set_min_proto_version(ctx, c.TLS1_2_VERSION);

        return .{ .ctx = ctx };
    }

    pub fn loadCertificate(self: *SslContext, cert_path: [*:0]const u8) SslError!void {
        if (c.SSL_CTX_use_certificate_chain_file(self.ctx, cert_path) != 1) {
            return SslError.CertificateLoadFailed;
        }
    }

    pub fn loadPrivateKey(self: *SslContext, key_path: [*:0]const u8) SslError!void {
        if (c.SSL_CTX_use_PrivateKey_file(self.ctx, key_path, c.SSL_FILETYPE_PEM) != 1) {
            return SslError.PrivateKeyLoadFailed;
        }
        if (c.SSL_CTX_check_private_key(self.ctx) != 1) {
            return SslError.KeyMismatch;
        }
    }

    pub fn deinit(self: *SslContext) void {
        c.SSL_CTX_free(self.ctx);
    }
};

/// SSL Connection - one per client connection
pub const SslConnection = struct {
    ssl: *SSL,
    fd: posix.fd_t,

    pub fn init(ctx: *SslContext, fd: posix.fd_t) SslError!SslConnection {
        const ssl = c.SSL_new(ctx.ctx) orelse return SslError.ConnectionFailed;
        errdefer c.SSL_free(ssl);

        if (c.SSL_set_fd(ssl, fd) != 1) {
            return SslError.ConnectionFailed;
        }

        return .{ .ssl = ssl, .fd = fd };
    }

    pub fn accept(self: *SslConnection) SslError!void {
        const result = c.SSL_accept(self.ssl);
        if (result != 1) {
            const err = c.SSL_get_error(self.ssl, result);
            return switch (err) {
                c.SSL_ERROR_WANT_READ, c.SSL_ERROR_WANT_WRITE => SslError.WouldBlock,
                else => SslError.HandshakeFailed,
            };
        }
    }

    pub fn read(self: *SslConnection, buf: []u8) SslError!usize {
        const result = c.SSL_read(self.ssl, buf.ptr, @intCast(buf.len));
        if (result <= 0) {
            const err = c.SSL_get_error(self.ssl, result);
            return switch (err) {
                c.SSL_ERROR_WANT_READ, c.SSL_ERROR_WANT_WRITE => SslError.WouldBlock,
                c.SSL_ERROR_ZERO_RETURN => SslError.Shutdown,
                else => SslError.ReadFailed,
            };
        }
        return @intCast(result);
    }

    pub fn write(self: *SslConnection, data: []const u8) SslError!usize {
        const result = c.SSL_write(self.ssl, data.ptr, @intCast(data.len));
        if (result <= 0) {
            const err = c.SSL_get_error(self.ssl, result);
            return switch (err) {
                c.SSL_ERROR_WANT_READ, c.SSL_ERROR_WANT_WRITE => SslError.WouldBlock,
                else => SslError.WriteFailed,
            };
        }
        return @intCast(result);
    }

    pub fn shutdown(self: *SslConnection) void {
        _ = c.SSL_shutdown(self.ssl);
    }

    pub fn deinit(self: *SslConnection) void {
        c.SSL_free(self.ssl);
    }
};

/// Get last OpenSSL error as string
pub fn getLastError() []const u8 {
    const err = c.ERR_get_error();
    if (err == 0) return "Unknown error";
    const ptr = c.ERR_error_string(err, null);
    if (ptr == null) return "Unknown error";
    return std.mem.span(ptr);
}
