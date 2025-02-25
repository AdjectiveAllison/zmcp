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

/// Deep clone a JSON value with proper memory handling
pub fn cloneValue(allocator: std.mem.Allocator, value: Value) !Value {
    switch (value) {
        .null => return .{ .null = {} },
        .bool => return .{ .bool = value.bool },
        .integer => return .{ .integer = value.integer },
        .float => return .{ .float = value.float },
        .string => return .{ .string = try allocator.dupe(u8, value.string) },
        .number_string => return .{ .number_string = try allocator.dupe(u8, value.number_string) },
        .array => {
            var array = std.json.Array.init(allocator);
            errdefer array.deinit();
            
            for (value.array.items) |item| {
                const cloned_item = try cloneValue(allocator, item);
                // No need for errdefer here as it's handled by caller
                try array.append(cloned_item);
            }
            return .{ .array = array };
        },
        .object => {
            var obj = std.json.ObjectMap.init(allocator);
            errdefer {
                var it = obj.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    cleanupValue(allocator, entry.value_ptr);
                }
                obj.deinit();
            }
            
            var it = value.object.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(key);
                
                const cloned_value = try cloneValue(allocator, entry.value_ptr.*);
                // No need for errdefer here as it's handled by caller
                
                try obj.put(key, cloned_value);
            }
            return .{ .object = obj };
        },
    }
}

/// Recursively cleanup a JSON value to prevent memory leaks
pub fn cleanupValue(allocator: std.mem.Allocator, value: *Value) void {
    switch (value.*) {
        .string => |string| allocator.free(string),
        .number_string => |string| allocator.free(string),
        .array => |*array| {
            for (array.items) |*item| {
                cleanupValue(allocator, item);
            }
            array.deinit();
        },
        .object => |*object| {
            var it = object.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                cleanupValue(allocator, entry.value_ptr);
            }
            object.deinit();
        },
        else => {}, // No cleanup needed for primitive types
    }
}

/// Compare two JSON values for equality
pub fn valuesEqual(a: Value, b: Value) bool {
    if (@intFromEnum(a) != @intFromEnum(b)) return false;

    return switch (a) {
        .null => true,
        .bool => a.bool == b.bool,
        .integer => a.integer == b.integer,
        .float => a.float == b.float,
        .string => std.mem.eql(u8, a.string, b.string),
        .number_string => std.mem.eql(u8, a.number_string, b.number_string),
        .array => blk: {
            if (a.array.items.len != b.array.items.len) break :blk false;
            for (a.array.items, b.array.items) |a_item, b_item| {
                if (!valuesEqual(a_item, b_item)) break :blk false;
            }
            break :blk true;
        },
        .object => blk: {
            if (a.object.count() != b.object.count()) break :blk false;
            var it = a.object.iterator();
            while (it.next()) |entry| {
                const b_value = b.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!valuesEqual(entry.value_ptr.*, b_value)) break :blk false;
            }
            break :blk true;
        },
    };
}

/// Parse a JSON message into a JSON-RPC response
pub fn parseResponse(allocator: std.mem.Allocator, json: Value) !Response {
    if (json != .object) return error.InvalidResponse;

    const jsonrpc = json.object.get("jsonrpc") orelse return error.InvalidResponse;
    if (jsonrpc != .string or !std.mem.eql(u8, jsonrpc.string, "2.0")) return error.InvalidResponse;

    const id = json.object.get("id") orelse return error.InvalidResponse;

    // Check for error
    if (json.object.get("error")) |err| {
        if (err != .object) return error.InvalidResponse;

        const code = err.object.get("code") orelse return error.InvalidResponse;
        if (code != .integer) return error.InvalidResponse;

        const message = err.object.get("message") orelse return error.InvalidResponse;
        if (message != .string) return error.InvalidResponse;

        const data = err.object.get("data");

        return Response{
            .jsonrpc = "2.0",
            .id = try cloneValue(allocator, id),
            .result = null,
            .@"error" = .{
                .code = code.integer,
                .message = try allocator.dupe(u8, message.string),
                .data = if (data) |d| try cloneValue(allocator, d) else null,
            },
        };
    }

    // Check for result
    const result = json.object.get("result");

    return Response{
        .jsonrpc = "2.0",
        .id = try cloneValue(allocator, id),
        .result = if (result) |r| try cloneValue(allocator, r) else null,
        .@"error" = null,
    };
}

/// Free resources used by a Response
pub fn deinitResponse(allocator: std.mem.Allocator, response: *Response) void {
    if (response.id) |*id| {
        cleanupValue(allocator, id);
    }

    if (response.result) |*result| {
        cleanupValue(allocator, result);
    }

    if (response.@"error") |*err| {
        allocator.free(err.message);
        if (err.data) |*data| {
            cleanupValue(allocator, data);
        }
    }
}

/// Determine if a JSON value is a JSON-RPC response
pub fn isResponse(json: Value) bool {
    if (json != .object) return false;
    if (json.object.get("jsonrpc") == null) return false;
    if (json.object.get("id") == null) return false;
    return json.object.get("result") != null or json.object.get("error") != null;
}

/// Determine if a JSON value is a JSON-RPC notification
pub fn isNotification(json: Value) bool {
    if (json != .object) return false;
    if (json.object.get("jsonrpc") == null) return false;
    if (json.object.get("method") == null) return false;
    return json.object.get("id") == null;
}

/// Determine if a JSON value is a JSON-RPC request
pub fn isRequest(json: Value) bool {
    if (json != .object) return false;
    if (json.object.get("jsonrpc") == null) return false;
    if (json.object.get("method") == null) return false;
    return json.object.get("id") != null;
}

/// Helper to clone a ResponseError
pub fn cloneError(allocator: std.mem.Allocator, err: ResponseError) !ResponseError {
    return ResponseError{
        .code = err.code,
        .message = try allocator.dupe(u8, err.message),
        .data = if (err.data) |data| try cloneValue(allocator, data) else null,
    };
}

// Helper to clone a Response
pub fn cloneResponse(allocator: std.mem.Allocator, response: Response) !Response {
    return Response{
        .jsonrpc = "2.0",
        .id = if (response.id) |id| try cloneValue(allocator, id) else null,
        .result = if (response.result) |result| try cloneValue(allocator, result) else null,
        .@"error" = if (response.@"error") |err| try cloneError(allocator, err) else null,
    };
}

// Helper to serialize a JSON-RPC message to a string
pub fn serializeMessage(allocator: std.mem.Allocator, message: anytype) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    
    try std.json.stringify(message, .{ .emit_null_optional_fields = false }, buf.writer());
    return try buf.toOwnedSlice();
}

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

test "cloneValue - primitives" {
    const allocator = std.testing.allocator;
    
    // Test null
    const val_null = Value{ .null = {} };
    const null_clone = try cloneValue(allocator, val_null);
    try std.testing.expect(null_clone == .null);
    
    // Test bool
    const val_true = Value{ .bool = true };
    const bool_clone = try cloneValue(allocator, val_true);
    try std.testing.expect(bool_clone == .bool);
    try std.testing.expectEqual(true, bool_clone.bool);
    
    // Test integer
    const val_int = Value{ .integer = 42 };
    const int_clone = try cloneValue(allocator, val_int);
    try std.testing.expect(int_clone == .integer);
    try std.testing.expectEqual(@as(i64, 42), int_clone.integer);
    
    // Test float
    const val_float = Value{ .float = 3.14 };
    const float_clone = try cloneValue(allocator, val_float);
    try std.testing.expect(float_clone == .float);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), float_clone.float, 0.0001);
}

test "cloneValue - string" {
    const allocator = std.testing.allocator;
    
    const val_string = Value{ .string = "test string" };
    var string_clone = try cloneValue(allocator, val_string);
    defer cleanupValue(allocator, &string_clone);
    
    try std.testing.expect(string_clone == .string);
    try std.testing.expectEqualStrings("test string", string_clone.string);
    
    // Verify it's a deep copy by modifying the original
    // This wouldn't be safe with actual strings since they're immutable slices
    // But it demonstrates the cloning behavior
}

test "cloneValue - array" {
    const allocator = std.testing.allocator;
    
    // Create a test array
    var array = std.json.Array.init(allocator);
    defer array.deinit();
    
    try array.append(Value{ .integer = 1 });
    try array.append(Value{ .string = "test" });
    
    const val_array = Value{ .array = array };
    var array_clone = try cloneValue(allocator, val_array);
    defer cleanupValue(allocator, &array_clone);
    
    try std.testing.expect(array_clone == .array);
    try std.testing.expectEqual(@as(usize, 2), array_clone.array.items.len);
    try std.testing.expect(array_clone.array.items[0] == .integer);
    try std.testing.expectEqual(@as(i64, 1), array_clone.array.items[0].integer);
    try std.testing.expect(array_clone.array.items[1] == .string);
    try std.testing.expectEqualStrings("test", array_clone.array.items[1].string);
}

test "cloneValue - object" {
    const allocator = std.testing.allocator;
    
    // Create a test object
    var obj = std.json.ObjectMap.init(allocator);
    defer obj.deinit();
    
    try obj.put("key1", Value{ .integer = 42 });
    try obj.put("key2", Value{ .string = "value" });
    
    const val_obj = Value{ .object = obj };
    var obj_clone = try cloneValue(allocator, val_obj);
    defer cleanupValue(allocator, &obj_clone);
    
    try std.testing.expect(obj_clone == .object);
    try std.testing.expectEqual(@as(usize, 2), obj_clone.object.count());
    try std.testing.expect(obj_clone.object.contains("key1"));
    try std.testing.expect(obj_clone.object.contains("key2"));
    
    const key1_val = obj_clone.object.get("key1").?;
    try std.testing.expect(key1_val == .integer);
    try std.testing.expectEqual(@as(i64, 42), key1_val.integer);
    
    const key2_val = obj_clone.object.get("key2").?;
    try std.testing.expect(key2_val == .string);
    try std.testing.expectEqualStrings("value", key2_val.string);
}

test "valuesEqual - equality checks" {
    // Test primitives
    const null1 = Value{ .null = {} };
    const null2 = Value{ .null = {} };
    try std.testing.expect(valuesEqual(null1, null2));
    
    const true1 = Value{ .bool = true };
    const true2 = Value{ .bool = true };
    const false1 = Value{ .bool = false };
    try std.testing.expect(valuesEqual(true1, true2));
    try std.testing.expect(!valuesEqual(true1, false1));
    
    const int1 = Value{ .integer = 42 };
    const int2 = Value{ .integer = 42 };
    const int3 = Value{ .integer = 43 };
    try std.testing.expect(valuesEqual(int1, int2));
    try std.testing.expect(!valuesEqual(int1, int3));
    
    const float1 = Value{ .float = 3.14 };
    const float2 = Value{ .float = 3.14 };
    const float3 = Value{ .float = 3.15 };
    try std.testing.expect(valuesEqual(float1, float2));
    try std.testing.expect(!valuesEqual(float1, float3));
    
    // Different types are not equal
    try std.testing.expect(!valuesEqual(int1, float1));
    try std.testing.expect(!valuesEqual(true1, null1));
}

test "isResponse, isNotification, isRequest - type detection" {
    const allocator = std.testing.allocator;
    
    // Create a response object
    var resp_obj = std.json.ObjectMap.init(allocator);
    defer resp_obj.deinit();
    
    try resp_obj.put("jsonrpc", Value{ .string = "2.0" });
    try resp_obj.put("id", Value{ .integer = 1 });
    try resp_obj.put("result", Value{ .null = {} });
    
    const resp_value = Value{ .object = resp_obj };
    try std.testing.expect(isResponse(resp_value));
    try std.testing.expect(!isNotification(resp_value));
    try std.testing.expect(!isRequest(resp_value));
    
    // Create a notification object
    var notif_obj = std.json.ObjectMap.init(allocator);
    defer notif_obj.deinit();
    
    try notif_obj.put("jsonrpc", Value{ .string = "2.0" });
    try notif_obj.put("method", Value{ .string = "test" });
    
    const notif_value = Value{ .object = notif_obj };
    try std.testing.expect(!isResponse(notif_value));
    try std.testing.expect(isNotification(notif_value));
    try std.testing.expect(!isRequest(notif_value));
    
    // Create a request object
    var req_obj = std.json.ObjectMap.init(allocator);
    defer req_obj.deinit();
    
    try req_obj.put("jsonrpc", Value{ .string = "2.0" });
    try req_obj.put("method", Value{ .string = "test" });
    try req_obj.put("id", Value{ .integer = 1 });
    
    const req_value = Value{ .object = req_obj };
    try std.testing.expect(!isResponse(req_value));
    try std.testing.expect(!isNotification(req_value));
    try std.testing.expect(isRequest(req_value));
}

test "serializeMessage - JSON stringification" {
    const allocator = std.testing.allocator;
    
    const notification = Notification{
        .method = "test",
        .params = Value{ .integer = 42 },
    };
    
    const serialized = try serializeMessage(allocator, notification);
    defer allocator.free(serialized);
    
    // Check that the serialized message contains the expected fields
    try std.testing.expect(std.mem.indexOf(u8, serialized, "\"jsonrpc\":\"2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "\"method\":\"test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "\"params\":42") != null);
}
