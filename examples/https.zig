const std = @import("std");
const spark = @import("spark");

const TlsIo = spark.TlsIo;
const HttpParser = spark.http.Parser;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize TLS I/O with certificate and key
    // Note: Run from project root or adjust paths
    var tls_io = try TlsIo.init(allocator, .{
        .cert_path = "examples/certs/cert.pem",
        .key_path = "examples/certs/key.pem",
        .max_connections = 1000,
        .buffer_size = 16 * 1024,
    });
    defer tls_io.deinit();

    const listen_fd = try tls_io.listen("0.0.0.0", 8443);

    std.log.info("HTTPS server listening on https://localhost:8443", .{});

    try tls_io.run(listen_fd, handleRequest, null);
}

fn handleRequest(conn: *TlsIo.Connection) void {
    // Parse HTTP request
    var parser = HttpParser.initWithLimits(.{});
    _ = parser.parse(conn.readData()) catch |err| {
        switch (err) {
            error.Incomplete => return,
            else => {
                const bad_request = "HTTP/1.1 400 Bad Request\r\nContent-Length: 11\r\n\r\nBad Request";
                @memcpy(conn.write_buffer[0..bad_request.len], bad_request);
                conn.write_len = bad_request.len;
                return;
            },
        }
    };

    // Send response
    const body =
        \\<!DOCTYPE html>
        \\<html>
        \\<head><title>Spark HTTPS</title></head>
        \\<body>
        \\<h1>Hello from Spark HTTPS!</h1>
        \\<p>TLS is working.</p>
        \\</body>
        \\</html>
    ;

    var response_buf: [1024]u8 = undefined;
    const response = std.fmt.bufPrint(&response_buf, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {d}\r\nConnection: keep-alive\r\n\r\n{s}", .{ body.len, body }) catch {
        return;
    };

    @memcpy(conn.write_buffer[0..response.len], response);
    conn.write_len = response.len;
}
