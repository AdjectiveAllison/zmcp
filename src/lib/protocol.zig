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
        if (json.object.get("jsonrpc")) |ver| {
            if (json.object.get("method")) |method| {
                return .{
                    .jsonrpc = ver.string,
                    .method = method.string,
                    .id = json.object.get("id"),
                    .params = json.object.get("params"),
                };
            } else return error.NoMethod;
        } else return error.NoJsonRpc;
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