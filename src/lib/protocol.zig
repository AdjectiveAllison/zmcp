const std = @import("std");

pub const ErrorCode = struct {
    pub const ParseError = -32700;
    pub const InvalidRequest = -32600;
    pub const MethodNotFound = -32601;
    pub const InvalidParams = -32602;
    pub const InternalError = -32603;
    pub const ServerNotInitialized = -32002;
    pub const UnknownErrorCode = -32001;
};

pub const Request = struct {
    jsonrpc: []const u8,
    method: []const u8,
    id: ?Value = null,
    params: ?Value = null,

    pub fn fromJson(json: std.json.Value) !Request {
        if (json != .object) return error.InvalidRequest;

        // Validate jsonrpc field
        const ver = json.object.get("jsonrpc") orelse return error.NoJsonRpc;
        if (ver != .string) return error.InvalidRequest;
        if (!std.mem.eql(u8, ver.string, "2.0")) return error.InvalidRequest;

        // Validate method field
        const method = json.object.get("method") orelse return error.NoMethod;
        if (method != .string) return error.InvalidRequest;

        // Validate id field if present
        const id = json.object.get("id");
        if (id) |id_val| {
            switch (id_val) {
                .string, .integer, .null => {},
                else => return error.InvalidRequest,
            }
        }

        // Validate params field if present
        const params = json.object.get("params");
        if (params) |params_val| {
            if (params_val != .object and params_val != .array) {
                return error.InvalidRequest;
            }
        }

        return .{
            .jsonrpc = ver.string,
            .method = method.string,
            .id = id,
            .params = params,
        };
    }

    pub fn isNotification(self: Request) bool {
        return self.id == null;
    }
};

pub const Response = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?Value,
    result: ?Value = null,
    @"error": ?ResponseError = null,

    pub fn success(id: ?Value, result: Value) Response {
        return .{
            .jsonrpc = "2.0",
            .id = id,
            .result = result,
            .@"error" = null,
        };
    }

    pub fn failure(id: ?Value, code: i64, message: []const u8) Response {
        return .{
            .jsonrpc = "2.0",
            .id = id,
            .result = null,
            .@"error" = .{
                .code = code,
                .message = message,
            },
        };
    }
};

pub const Notification = struct {
    jsonrpc: []const u8 = "2.0",
    method: []const u8,
    params: ?Value,

    pub fn create(method: []const u8, params: ?Value) Notification {
        return .{
            .jsonrpc = "2.0",
            .method = method,
            .params = params,
        };
    }
};

pub const ResponseError = struct {
    code: i64,
    message: []const u8,
    data: ?Value = null,
};

pub const Value = std.json.Value;

test "Request.fromJson - valid request" {
    const allocator = std.testing.allocator;

    var obj = std.json.ObjectMap.init(allocator);
    defer obj.deinit();

    try obj.put("jsonrpc", .{ .string = "2.0" });
    try obj.put("method", .{ .string = "test" });
    try obj.put("id", .{ .integer = 1 });
    try obj.put("params", .{ .object = std.json.ObjectMap.init(allocator) });

    const request = try Request.fromJson(.{ .object = obj });
    try std.testing.expectEqualStrings("2.0", request.jsonrpc);
    try std.testing.expectEqualStrings("test", request.method);
    try std.testing.expect(request.id != null);
    try std.testing.expect(request.params != null);
}

test "Request.fromJson - invalid jsonrpc version" {
    const allocator = std.testing.allocator;

    var obj = std.json.ObjectMap.init(allocator);
    defer obj.deinit();

    try obj.put("jsonrpc", .{ .string = "1.0" });
    try obj.put("method", .{ .string = "test" });

    try std.testing.expectError(error.InvalidRequest, Request.fromJson(.{ .object = obj }));
}

test "Request.fromJson - non-string jsonrpc" {
    const allocator = std.testing.allocator;

    var obj = std.json.ObjectMap.init(allocator);
    defer obj.deinit();

    try obj.put("jsonrpc", .{ .integer = 2 });
    try obj.put("method", .{ .string = "test" });

    try std.testing.expectError(error.InvalidRequest, Request.fromJson(.{ .object = obj }));
}

test "Request.fromJson - non-string method" {
    const allocator = std.testing.allocator;

    var obj = std.json.ObjectMap.init(allocator);
    defer obj.deinit();

    try obj.put("jsonrpc", .{ .string = "2.0" });
    try obj.put("method", .{ .integer = 123 });

    try std.testing.expectError(error.InvalidRequest, Request.fromJson(.{ .object = obj }));
}

test "Request.fromJson - invalid id type" {
    const allocator = std.testing.allocator;

    var obj = std.json.ObjectMap.init(allocator);
    defer obj.deinit();

    try obj.put("jsonrpc", .{ .string = "2.0" });
    try obj.put("method", .{ .string = "test" });
    try obj.put("id", .{ .bool = true });

    try std.testing.expectError(error.InvalidRequest, Request.fromJson(.{ .object = obj }));
}

test "Request.fromJson - invalid params type" {
    const allocator = std.testing.allocator;

    var obj = std.json.ObjectMap.init(allocator);
    defer obj.deinit();

    try obj.put("jsonrpc", .{ .string = "2.0" });
    try obj.put("method", .{ .string = "test" });
    try obj.put("params", .{ .string = "invalid" });

    try std.testing.expectError(error.InvalidRequest, Request.fromJson(.{ .object = obj }));
}

test "Request.fromJson - notification" {
    const allocator = std.testing.allocator;

    var obj = std.json.ObjectMap.init(allocator);
    defer obj.deinit();

    try obj.put("jsonrpc", .{ .string = "2.0" });
    try obj.put("method", .{ .string = "test" });

    const request = try Request.fromJson(.{ .object = obj });
    try std.testing.expectEqualStrings("2.0", request.jsonrpc);
    try std.testing.expectEqualStrings("test", request.method);
    try std.testing.expect(request.id == null);
    try std.testing.expect(request.params == null);
    try std.testing.expect(request.isNotification());
}
