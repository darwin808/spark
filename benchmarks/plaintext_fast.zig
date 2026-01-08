const std = @import("std");
const spark = @import("spark");

const Io = spark.Io;
const HttpParser = spark.http.Parser;
const date_cache = spark.core.date_cache;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var io = try Io.init(allocator, .{
        .max_connections = 10000,
        .buffer_size = 16 * 1024,
    });
    defer io.deinit();

    const listen_fd = try io.listen("127.0.0.1", 9000);
    std.log.info("Fast plaintext listening on http://127.0.0.1:9000", .{});

    try io.run(listen_fd, handleRequest, null);
}

fn handleRequest(conn: *Io.Connection) void {
    // Update date cache
    date_cache.global.update();

    // Parse just to consume the request
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

    // Static response - no allocations
    const response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\n\r\nHello, World!";
    @memcpy(conn.write_buffer[0..response.len], response);
    conn.write_len = response.len;
}
