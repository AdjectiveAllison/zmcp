const std = @import("std");
const testing = std.testing;
const new_tool = @import("new_tool.zig");

fn simpleHandler(message: []const u8) ![]const u8 {
    return message;
}

fn invalidHandler(message: *const u32) !void {
    _ = message;
}

test "Tool validates handler parameters" {
    // This should compile - valid handler
    const tool = new_tool.Tool.init(
        "test",
        "Test tool",
        simpleHandler,
    );
    try testing.expectEqualStrings("test", tool.name);
    try testing.expectEqualStrings("Test tool", tool.description);
}

test "Tool rejects invalid handler parameters" {
    // This should fail to compile - invalid parameter type
    const tool = new_tool.Tool.init(
        "test",
        "Test tool",
        invalidHandler,
    );
    _ = tool;
}

const InputStruct = struct {
    message: []const u8,
    count: i64,
    enabled: bool,
};

fn complexHandler(input: InputStruct) !InputStruct {
    return input;
}

test "Tool supports struct parameters" {
    // This should compile - valid struct with supported types
    const tool = new_tool.Tool.init(
        "complex",
        "Complex tool",
        complexHandler,
    );
    try testing.expectEqualStrings("complex", tool.name);
}
