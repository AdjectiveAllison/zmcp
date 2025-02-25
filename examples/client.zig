const std = @import("std");
const zmcp = @import("zmcp");

// Simple context for progress and log handling
const AppContext = struct {
    allocator: std.mem.Allocator,
    last_progress: f64 = 0,
};

// Progress callback function
fn onProgress(token: zmcp.protocol.Value, progress: f64, total: ?f64, context: ?*anyopaque) void {
    _ = token;
    const app_context = @as(*AppContext, @alignCast(@ptrCast(context.?)));
    app_context.last_progress = progress;

    const stderr = std.io.getStdErr().writer();
    if (total) |t| {
        stderr.print("\rProgress: {d:.1}% ({d:.1}/{d:.1})", .{ progress / t * 100.0, progress, t }) catch {};
    } else {
        stderr.print("\rProgress: {d:.1}", .{progress}) catch {};
    }
}

// Log callback function
fn onLog(level: []const u8, message: []const u8, context: ?*anyopaque) void {
    _ = context;
    const stderr = std.io.getStdErr().writer();
    stderr.print("\n[{s}] {s}\n", .{ level, message }) catch {};
}

// Tools changed callback
fn onToolsChanged(context: ?*anyopaque) void {
    _ = context;
    const stderr = std.io.getStdErr().writer();
    stderr.print("\nTools list has changed!\n", .{}) catch {};
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app_context = AppContext{
        .allocator = allocator,
    };

    // Find server path for connection
    const server_path = try findServerPath(allocator);
    defer allocator.free(server_path);

    // Create client with builder pattern
    var client = try zmcp.Client.builder(allocator)
        .withName("Example Client")
        .withVersion("1.0.0")
        .withCommand(server_path, &[_][]const u8{})
        .withDebugLogging(true)
        .withProgressHandler(onProgress)
        .withLogHandler(onLog)
        .withToolsChangedHandler(onToolsChanged)
        .withUserContext(&app_context)
        .build();
    defer client.deinit();

    // List available tools
    std.debug.print("Available tools:\n", .{});
    const tools = try client.listTools();
    defer {
        for (tools) |*tool| {
            // Clean up each tool
            zmcp.protocol.cleanupValue(allocator, tool);
        }
        allocator.free(tools);
    }

    for (tools) |tool| {
        if (tool != .object) continue;
        const name = tool.object.get("name") orelse continue;
        const description = tool.object.get("description") orelse continue;
        if (name != .string or description != .string) continue;

        std.debug.print("- {s}: {s}\n", .{ name.string, description.string });
    }

    // Exit if no tools are available
    if (tools.len == 0) {
        std.debug.print("No tools available.\n", .{});
        return;
    }

    // Call a tool with progress tracking
    const selected_tool = tools[0].object.get("name").?.string;
    std.debug.print("\nCalling tool '{s}'...\n", .{selected_tool});

    // Create a progress token
    const progress_token = zmcp.protocol.Value{ .string = try allocator.dupe(u8, "progress-token") };
    defer if (progress_token == .string) allocator.free(progress_token.string);

    // Using the simplified callToolText API
    const text_result = try client.callToolText(
        selected_tool,
        .{
            .message = "Hello from client!",
            .count = 3,
        },
        .{
            .progress_token = progress_token,
            .timeout_ms = 10000,
        },
    );
    defer allocator.free(text_result);

    std.debug.print("\n\nTool call result: {s}\n", .{text_result});

    // Also demonstrate the regular callTool API
    var call_result = try client.callTool(
        selected_tool,
        .{
            .message = "Another message",
            .count = 2,
        },
        .{
            .timeout_ms = 5000,
        },
    );
    defer call_result.deinit(allocator);

    // Print the result
    std.debug.print("\nRegular tool call result:\n", .{});
    std.debug.print("Is error: {}\n", .{call_result.is_error});

    for (call_result.content) |content| {
        if (content != .object) continue;

        const content_type = content.object.get("type") orelse continue;
        if (content_type != .string) continue;

        if (std.mem.eql(u8, content_type.string, "text")) {
            const text = content.object.get("text") orelse continue;
            if (text != .string) continue;
            std.debug.print("Content: {s}\n", .{text.string});
        }
    }

    // Set log level to debug
    try client.setLogLevel("debug");
    std.debug.print("\nSet log level to debug\n", .{});
}

fn findServerPath(allocator: std.mem.Allocator) ![]const u8 {
    // For simplicity in this example, we'll assume the server is in the same directory
    // as the client and named "echo-example"
    return allocator.dupe(u8, "./zig-out/bin/echo-example");
}
