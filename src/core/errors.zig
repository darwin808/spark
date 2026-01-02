const std = @import("std");
const Status = @import("../http/status.zig").Status;

/// User-friendly error with context.
pub const SparkError = struct {
    kind: Kind,
    message: []const u8,
    field: ?[]const u8 = null,

    pub const Kind = enum {
        bad_request,
        unauthorized,
        forbidden,
        not_found,
        method_not_allowed,
        conflict,
        unprocessable_entity,
        too_many_requests,
        internal,
        not_implemented,
        service_unavailable,
        parse_error,
        validation_error,
        timeout,
    };

    pub fn init(kind: Kind, message: []const u8) SparkError {
        return .{ .kind = kind, .message = message };
    }

    pub fn withField(self: SparkError, field: []const u8) SparkError {
        var err = self;
        err.field = field;
        return err;
    }

    pub fn status(self: SparkError) Status {
        return switch (self.kind) {
            .bad_request, .parse_error => .bad_request,
            .unauthorized => .unauthorized,
            .forbidden => .forbidden,
            .not_found => .not_found,
            .method_not_allowed => .method_not_allowed,
            .conflict => .conflict,
            .unprocessable_entity, .validation_error => .unprocessable_entity,
            .too_many_requests => .too_many_requests,
            .internal => .internal_server_error,
            .not_implemented => .not_implemented,
            .service_unavailable, .timeout => .service_unavailable,
        };
    }
};

/// Validation error builder.
pub const ValidationErrors = struct {
    errors: std.ArrayList(FieldError),
    allocator: std.mem.Allocator,

    pub const FieldError = struct {
        field: []const u8,
        message: []const u8,
        code: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) ValidationErrors {
        return .{
            .errors = std.ArrayList(FieldError).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn add(self: *ValidationErrors, field: []const u8, code: []const u8, message: []const u8) void {
        self.errors.append(.{
            .field = field,
            .code = code,
            .message = message,
        }) catch {};
    }

    pub fn required(self: *ValidationErrors, field: []const u8) void {
        self.add(field, "required", "This field is required");
    }

    pub fn invalid(self: *ValidationErrors, field: []const u8, message: []const u8) void {
        self.add(field, "invalid", message);
    }

    pub fn minLength(self: *ValidationErrors, field: []const u8, min: usize) void {
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Must be at least {d} characters", .{min}) catch "Too short";
        self.add(field, "min_length", msg);
    }

    pub fn maxLength(self: *ValidationErrors, field: []const u8, max: usize) void {
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Must be at most {d} characters", .{max}) catch "Too long";
        self.add(field, "max_length", msg);
    }

    pub fn hasErrors(self: *const ValidationErrors) bool {
        return self.errors.items.len > 0;
    }

    pub fn toResponse(self: *const ValidationErrors) ValidationResponse {
        return .{
            .@"error" = .{
                .code = "validation_error",
                .message = "Validation failed",
                .fields = self.errors.items,
            },
        };
    }

    pub fn deinit(self: *ValidationErrors) void {
        self.errors.deinit();
    }
};

pub const ValidationResponse = struct {
    @"error": struct {
        code: []const u8,
        message: []const u8,
        fields: []const ValidationErrors.FieldError,
    },
};
