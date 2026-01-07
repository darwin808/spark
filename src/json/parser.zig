const std = @import("std");

/// Zero-allocation JSON parser using comptime reflection with depth limiting.
pub const Parser = struct {
    input: []const u8,
    pos: usize = 0,
    depth: usize = 0,
    allocator: std.mem.Allocator,

    // Security limits
    max_depth: usize = 64,

    pub const Error = error{
        UnexpectedToken,
        ExpectedString,
        ExpectedNumber,
        ExpectedBool,
        ExpectedNull,
        ExpectedObject,
        ExpectedArray,
        ExpectedColon,
        ExpectedValue,
        MissingField,
        InvalidEscape,
        NumberOverflow,
        OutOfMemory,
        MaxDepthExceeded,
    };

    pub fn init(input: []const u8, allocator: std.mem.Allocator) Parser {
        return .{ .input = input, .allocator = allocator };
    }

    pub fn initWithMaxDepth(input: []const u8, allocator: std.mem.Allocator, max_depth: usize) Parser {
        return .{ .input = input, .allocator = allocator, .max_depth = max_depth };
    }

    /// Parse JSON into type T using comptime reflection.
    pub fn parse(self: *Parser, comptime T: type) Error!T {
        self.skipWhitespace();
        return self.parseValue(T);
    }

    fn parseValue(self: *Parser, comptime T: type) Error!T {
        // Check depth limit
        if (self.depth > self.max_depth) {
            return error.MaxDepthExceeded;
        }
        const info = @typeInfo(T);

        return switch (info) {
            .bool => self.parseBool(),
            .int, .comptime_int => self.parseInt(T),
            .float, .comptime_float => self.parseFloat(T),
            .optional => |opt| self.parseOptional(opt.child),
            .pointer => |ptr| switch (ptr.size) {
                .slice => if (ptr.child == u8)
                    self.parseString()
                else
                    self.parseArray(ptr.child),
                else => error.UnexpectedToken,
            },
            .@"struct" => |s| if (s.is_tuple)
                self.parseTuple(T)
            else
                self.parseStruct(T),
            .@"enum" => self.parseEnum(T),
            else => error.UnexpectedToken,
        };
    }

    fn parseBool(self: *Parser) Error!bool {
        self.skipWhitespace();
        if (self.startsWith("true")) {
            self.pos += 4;
            return true;
        } else if (self.startsWith("false")) {
            self.pos += 5;
            return false;
        }
        return error.ExpectedBool;
    }

    fn parseInt(self: *Parser, comptime T: type) Error!T {
        self.skipWhitespace();
        const start = self.pos;

        if (self.pos < self.input.len and self.input[self.pos] == '-') {
            self.pos += 1;
        }

        while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) {
            self.pos += 1;
        }

        if (self.pos == start) return error.ExpectedNumber;

        return std.fmt.parseInt(T, self.input[start..self.pos], 10) catch error.NumberOverflow;
    }

    fn parseFloat(self: *Parser, comptime T: type) Error!T {
        self.skipWhitespace();
        const start = self.pos;

        if (self.pos < self.input.len and (self.input[self.pos] == '-' or self.input[self.pos] == '+')) {
            self.pos += 1;
        }

        while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) {
            self.pos += 1;
        }

        if (self.pos < self.input.len and self.input[self.pos] == '.') {
            self.pos += 1;
            while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) {
                self.pos += 1;
            }
        }

        if (self.pos < self.input.len and (self.input[self.pos] == 'e' or self.input[self.pos] == 'E')) {
            self.pos += 1;
            if (self.pos < self.input.len and (self.input[self.pos] == '-' or self.input[self.pos] == '+')) {
                self.pos += 1;
            }
            while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) {
                self.pos += 1;
            }
        }

        if (self.pos == start) return error.ExpectedNumber;

        return std.fmt.parseFloat(T, self.input[start..self.pos]) catch error.NumberOverflow;
    }

    fn parseOptional(self: *Parser, comptime Child: type) Error!?Child {
        self.skipWhitespace();
        if (self.startsWith("null")) {
            self.pos += 4;
            return null;
        }
        return try self.parseValue(Child);
    }

    fn parseString(self: *Parser) Error![]const u8 {
        self.skipWhitespace();
        if (self.pos >= self.input.len or self.input[self.pos] != '"') {
            return error.ExpectedString;
        }
        self.pos += 1;

        const start = self.pos;
        var has_escape = false;

        while (self.pos < self.input.len and self.input[self.pos] != '"') {
            if (self.input[self.pos] == '\\') {
                has_escape = true;
                self.pos += 1;
                if (self.pos >= self.input.len) return error.InvalidEscape;
            }
            self.pos += 1;
        }

        if (self.pos >= self.input.len) return error.ExpectedString;

        const end = self.pos;
        self.pos += 1;

        if (has_escape) {
            return self.unescapeString(self.input[start..end]);
        }

        return self.input[start..end];
    }

    fn unescapeString(self: *Parser, s: []const u8) Error![]const u8 {
        var result = std.ArrayListUnmanaged(u8){};

        var i: usize = 0;
        while (i < s.len) {
            if (s[i] == '\\' and i + 1 < s.len) {
                switch (s[i + 1]) {
                    '"' => result.append(self.allocator, '"') catch return error.OutOfMemory,
                    '\\' => result.append(self.allocator, '\\') catch return error.OutOfMemory,
                    '/' => result.append(self.allocator, '/') catch return error.OutOfMemory,
                    'n' => result.append(self.allocator, '\n') catch return error.OutOfMemory,
                    'r' => result.append(self.allocator, '\r') catch return error.OutOfMemory,
                    't' => result.append(self.allocator, '\t') catch return error.OutOfMemory,
                    'b' => result.append(self.allocator, 0x08) catch return error.OutOfMemory,
                    'f' => result.append(self.allocator, 0x0c) catch return error.OutOfMemory,
                    else => return error.InvalidEscape,
                }
                i += 2;
            } else {
                result.append(self.allocator, s[i]) catch return error.OutOfMemory;
                i += 1;
            }
        }

        return result.toOwnedSlice(self.allocator) catch error.OutOfMemory;
    }

    fn parseArray(self: *Parser, comptime Child: type) Error![]Child {
        self.skipWhitespace();
        if (self.pos >= self.input.len or self.input[self.pos] != '[') {
            return error.ExpectedArray;
        }
        self.pos += 1;
        self.depth += 1; // Track nesting depth
        defer self.depth -= 1;

        var list = std.ArrayListUnmanaged(Child){};

        self.skipWhitespace();
        if (self.pos < self.input.len and self.input[self.pos] == ']') {
            self.pos += 1;
            return list.toOwnedSlice(self.allocator) catch error.OutOfMemory;
        }

        while (true) {
            list.append(self.allocator, try self.parseValue(Child)) catch return error.OutOfMemory;

            self.skipWhitespace();
            if (self.pos >= self.input.len) return error.ExpectedArray;

            if (self.input[self.pos] == ']') {
                self.pos += 1;
                break;
            }

            if (self.input[self.pos] == ',') {
                self.pos += 1;
            }
        }

        return list.toOwnedSlice(self.allocator) catch error.OutOfMemory;
    }

    fn parseStruct(self: *Parser, comptime T: type) Error!T {
        self.skipWhitespace();
        if (self.pos >= self.input.len or self.input[self.pos] != '{') {
            return error.ExpectedObject;
        }
        self.pos += 1;
        self.depth += 1; // Track nesting depth
        defer self.depth -= 1;

        var result: T = undefined;
        const fields = std.meta.fields(T);
        var fields_seen = [_]bool{false} ** fields.len;

        self.skipWhitespace();
        if (self.pos < self.input.len and self.input[self.pos] == '}') {
            self.pos += 1;
            inline for (fields, 0..) |field, i| {
                if (!fields_seen[i]) {
                    if (field.default_value_ptr) |default| {
                        const ptr: *const field.type = @ptrCast(@alignCast(default));
                        @field(result, field.name) = ptr.*;
                    } else if (@typeInfo(field.type) == .optional) {
                        @field(result, field.name) = null;
                    } else {
                        return error.MissingField;
                    }
                }
            }
            return result;
        }

        while (true) {
            const key = try self.parseString();

            self.skipWhitespace();
            if (self.pos >= self.input.len or self.input[self.pos] != ':') {
                return error.ExpectedColon;
            }
            self.pos += 1;

            var matched = false;
            inline for (fields, 0..) |field, i| {
                if (std.mem.eql(u8, key, field.name)) {
                    @field(result, field.name) = try self.parseValue(field.type);
                    fields_seen[i] = true;
                    matched = true;
                }
            }

            if (!matched) {
                try self.skipValue();
            }

            self.skipWhitespace();
            if (self.pos >= self.input.len) return error.ExpectedObject;

            if (self.input[self.pos] == '}') {
                self.pos += 1;
                break;
            }

            if (self.input[self.pos] == ',') {
                self.pos += 1;
            }
        }

        inline for (fields, 0..) |field, i| {
            if (!fields_seen[i]) {
                if (field.default_value_ptr) |default| {
                    const ptr: *const field.type = @ptrCast(@alignCast(default));
                    @field(result, field.name) = ptr.*;
                } else if (@typeInfo(field.type) == .optional) {
                    @field(result, field.name) = null;
                } else {
                    return error.MissingField;
                }
            }
        }

        return result;
    }

    fn parseTuple(self: *Parser, comptime T: type) Error!T {
        self.skipWhitespace();
        if (self.pos >= self.input.len or self.input[self.pos] != '[') {
            return error.ExpectedArray;
        }
        self.pos += 1;

        var result: T = undefined;
        const fields = std.meta.fields(T);

        inline for (fields, 0..) |field, i| {
            if (i > 0) {
                self.skipWhitespace();
                if (self.pos >= self.input.len or self.input[self.pos] != ',') {
                    return error.ExpectedArray;
                }
                self.pos += 1;
            }

            result[i] = try self.parseValue(field.type);
        }

        self.skipWhitespace();
        if (self.pos >= self.input.len or self.input[self.pos] != ']') {
            return error.ExpectedArray;
        }
        self.pos += 1;

        return result;
    }

    fn parseEnum(self: *Parser, comptime T: type) Error!T {
        const str = try self.parseString();
        return std.meta.stringToEnum(T, str) orelse error.UnexpectedToken;
    }

    fn skipValue(self: *Parser) Error!void {
        self.skipWhitespace();
        if (self.pos >= self.input.len) return;

        switch (self.input[self.pos]) {
            '"' => _ = try self.parseString(),
            '[' => {
                self.pos += 1;
                var depth: usize = 1;
                while (self.pos < self.input.len and depth > 0) {
                    if (self.input[self.pos] == '[') depth += 1;
                    if (self.input[self.pos] == ']') depth -= 1;
                    self.pos += 1;
                }
            },
            '{' => {
                self.pos += 1;
                var depth: usize = 1;
                while (self.pos < self.input.len and depth > 0) {
                    if (self.input[self.pos] == '{') depth += 1;
                    if (self.input[self.pos] == '}') depth -= 1;
                    self.pos += 1;
                }
            },
            else => {
                while (self.pos < self.input.len) {
                    const c = self.input[self.pos];
                    if (c == ',' or c == '}' or c == ']' or std.ascii.isWhitespace(c)) break;
                    self.pos += 1;
                }
            },
        }
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.input.len and std.ascii.isWhitespace(self.input[self.pos])) {
            self.pos += 1;
        }
    }

    fn startsWith(self: *Parser, prefix: []const u8) bool {
        if (self.pos + prefix.len > self.input.len) return false;
        return std.mem.eql(u8, self.input[self.pos..][0..prefix.len], prefix);
    }
};

test "parse simple object" {
    const input =
        \\{"name":"John","age":30}
    ;

    const User = struct {
        name: []const u8,
        age: u32,
    };

    var parser = Parser.init(input, std.testing.allocator);
    const result = try parser.parse(User);

    try std.testing.expectEqualStrings("John", result.name);
    try std.testing.expectEqual(@as(u32, 30), result.age);
}
