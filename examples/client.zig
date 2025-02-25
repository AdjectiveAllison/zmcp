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
    std.debug.print("Starting client...\n", .{});
    std.debug.print("Finding server executable...\n", .{});

    const server_path = try findServerPath(allocator);
    defer allocator.free(server_path);

    std.debug.print("Using server at: {s}\n", .{server_path});

    // Verify the executable exists and is readable
    std.fs.cwd().access(server_path, .{}) catch {
        std.debug.print("ERROR: Server executable not found at {s}\n", .{server_path});
        std.debug.print("Make sure to run 'zig build build-echo' first\n", .{});
        return error.ServerNotFound;
    };

    std.debug.print("Server executable verified!\n", .{});

    // Create client with builder pattern
    std.debug.print("Creating client and connecting to server...\n", .{});
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

    std.debug.print("Client connected to server successfully!\n", .{});

    // List available tools
    std.debug.print("\nListing available tools...\n", .{});

    const tools = client.listTools() catch |err| {
        std.debug.print("Error listing tools: {s}\n", .{@errorName(err)});
        return err;
    };

    std.debug.print("Found {d} tools.\n", .{tools.len});

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

    // Using the simplified callToolText API with shorter timeout
    std.debug.print("Sending tool call with text return (5s timeout)...\n", .{});

    const text_result = client.callToolText(
        selected_tool,
        .{
            .message = "Hello from client!",
            .count = 3,
        },
        .{
            .progress_token = progress_token,
            .timeout_ms = 5000, // Use a shorter timeout to fail faster if there's an issue
        },
    ) catch |err| {
        std.debug.print("Error calling tool: {s}\n", .{@errorName(err)});
        return err;
    };
    defer allocator.free(text_result);

    std.debug.print("\nTool call succeeded!\n", .{});
    std.debug.print("Result: {s}\n", .{text_result});

    // Also demonstrate the regular callTool API
    std.debug.print("\nCalling tool with full result object...\n", .{});

    var call_result = client.callTool(
        selected_tool,
        .{
            .message = "Another message",
            .count = 2,
        },
        .{
            .timeout_ms = 5000,
        },
    ) catch |err| {
        std.debug.print("Error calling tool: {s}\n", .{@errorName(err)});
        return err;
    };
    defer call_result.deinit(allocator);

    // Print the result
    std.debug.print("\nRegular tool call succeeded!\n", .{});
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
    std.debug.print("\nSetting log level to debug...\n", .{});

    client.setLogLevel("debug") catch |err| {
        std.debug.print("Error setting log level: {s}\n", .{@errorName(err)});
        return err;
    };

    std.debug.print("Log level set successfully.\n", .{});
    std.debug.print("\nClient test completed successfully!\n", .{});
}

fn findServerPath(allocator: std.mem.Allocator) ![]const u8 {
    // First check the standard zig-out/bin location
    const standard_path = "./zig-out/bin/echo-example";

    // Test if file exists
    if (std.fs.cwd().access(standard_path, .{})) {
        return allocator.dupe(u8, standard_path);
    } else |_| {
        // Print detailed debugging info to help find the executable
        std.debug.print("Could not find server at standard path: {s}\n", .{standard_path});

        // Get current working directory
        var cwd_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const cwd = try std.posix.getcwd(&cwd_buf); // Fixed: std.os.getcwd -> std.posix.getcwd
        std.debug.print("Current working directory: {s}\n", .{cwd});

        // Try to check zig-out/bin directory
        var bin_dir = std.fs.cwd().openDir("zig-out/bin", .{ .iterate = true }) catch |err| {
            std.debug.print("Could not open zig-out/bin directory: {s}\n", .{@errorName(err)});
            return allocator.dupe(u8, standard_path); // Return standard path even though we know it doesn't exist
        };
        defer bin_dir.close();

        // List all files in bin directory
        var it = bin_dir.iterate();
        std.debug.print("Contents of zig-out/bin directory:\n", .{});
        while (try it.next()) |entry| {
            std.debug.print("  {s} ({s})\n", .{ entry.name, @tagName(entry.kind) });

            // If we find the echo-example, use it
            if (std.mem.eql(u8, entry.name, "echo-example")) {
                const full_path = try std.fs.path.join(allocator, &[_][]const u8{ "zig-out/bin", entry.name });
                return full_path;
            }
        }

        // If we got here, we couldn't find the echo example in the expected location
        std.debug.print("WARNING: Could not find echo-example in expected locations.\n", .{});
        return allocator.dupe(u8, standard_path);
    }
}
