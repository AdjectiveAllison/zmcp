const std = @import("std");
const zmcp = @import("zmcp");

fn echoFn(message: []const u8) ![]const u8 {
    return message;
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
    "Echo back a message",
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
