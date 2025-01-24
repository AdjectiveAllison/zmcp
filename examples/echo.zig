const std = @import("std");
const zmcp = @import("zmcp");

const EchoParams = struct {
    allocator: std.mem.Allocator,
    message: []const u8,
    prefix: ?[]const u8 = null,
    count: u32 = 1,
};

fn echoFn(params: EchoParams) ![]const u8 {
    var result = std.ArrayList(u8).init(params.allocator);
    errdefer result.deinit();

    if (params.prefix) |prefix| {
        try result.writer().print("{s}: {s}", .{ prefix, params.message });
    } else {
        try result.writer().writeAll(params.message);
    }

    if (params.count > 1) {
        const initial = try result.toOwnedSlice();
        defer params.allocator.free(initial);

        result = std.ArrayList(u8).init(params.allocator);
        errdefer result.deinit();

        try result.writer().writeAll(initial);
        for (1..params.count) |_| {
            try result.writer().print("\n{s}", .{initial});
        }
    }

    // Return the final result
    return result.toOwnedSlice();
}

// This will all be validated at comp time by zmcp. zmcp will check the echoFn paramers and return types and ensure they are compatible with `std.json.Value` and subsequently the MCP schema. Schema will be generated automatically from the tool at comptime.
// Supported parameter types initially match JSON Value types:

// These will be auto translated by the zmcp implementation.
// Strings ([]const u8)
// Integers (i64)
// Floats (f64)
// Booleans
// Arrays of supported types
// Optional versions of above types

const echo_tool = zmcp.Tool(
    "echo",
    "Echo back a message with optional prefix and repeat count",
    echoFn,
);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try zmcp.Server.init(allocator, "Example Server", "1.0.0");
    defer server.deinit();

    try server.addTool(echo_tool);
    try server.start();
}
