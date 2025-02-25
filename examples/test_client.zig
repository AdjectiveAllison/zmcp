const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Find the server path
    std.debug.print("Simple Test Client Starting\n", .{});
    const server_path = "./zig-out/bin/echo-example";

    // Get current working directory for debugging
    var cwd_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const cwd = try std.posix.getcwd(&cwd_buf); // Fixed: std.os.getcwd -> std.posix.getcwd
    std.debug.print("Current working directory: {s}\n", .{cwd});

    // Verify server exists
    std.fs.cwd().access(server_path, .{}) catch {
        std.debug.print("ERROR: Server not found at {s}\n", .{server_path});
        std.debug.print("Run 'zig build build-echo' first\n", .{});
        return error.ServerNotFound;
    };

    std.debug.print("Found server at: {s}\n", .{server_path});

    // Launch the server process
    std.debug.print("Launching server process...\n", .{});
    var process = std.process.Child.init(&[_][]const u8{server_path}, allocator);
    process.stdin_behavior = .Pipe;
    process.stdout_behavior = .Pipe;
    process.stderr_behavior = .Pipe;

    try process.spawn();
    std.debug.print("Server process spawned\n", .{});

    // Create a simple JSON-RPC initialize message
    const init_message =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"TestClient","version":"1.0.0"}}}
    ;

    // Send the initialize message
    std.debug.print("Sending initialize message...\n", .{});
    try process.stdin.?.writer().print("{s}\n", .{init_message});

    // Read response
    std.debug.print("Reading response...\n", .{});
    var buf: [8192]u8 = undefined;

    // Try to read with timeout
    const response = try readWithTimeout(process.stdout.?, &buf, 2000) orelse {
        std.debug.print("ERROR: No response received within timeout\n", .{});
        // Kill the process
        _ = process.kill() catch {};
        return error.NoResponse;
    };

    std.debug.print("Response received: {s}\n", .{response});

    // Send initialized notification
    const initialized_message =
        \\{"jsonrpc":"2.0","method":"initialized"}
    ;

    std.debug.print("Sending initialized notification...\n", .{});
    try process.stdin.?.writer().print("{s}\n", .{initialized_message});

    // List tools
    const list_tools_message =
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
    ;

    std.debug.print("Sending tools/list request...\n", .{});
    try process.stdin.?.writer().print("{s}\n", .{list_tools_message});

    // Read response
    const tools_response = try readWithTimeout(process.stdout.?, &buf, 2000) orelse {
        std.debug.print("ERROR: No tools/list response received within timeout\n", .{});
        // Kill the process
        _ = process.kill() catch {};
        return error.NoResponse;
    };

    std.debug.print("Tools response received: {s}\n", .{tools_response});

    // Call echo tool
    const call_tool_message =
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"message":"Hello from test client","count":3}}}
    ;

    std.debug.print("Sending tools/call request...\n", .{});
    try process.stdin.?.writer().print("{s}\n", .{call_tool_message});

    // Read response
    const call_response = try readWithTimeout(process.stdout.?, &buf, 2000) orelse {
        std.debug.print("ERROR: No tools/call response received within timeout\n", .{});
        // Kill the process
        _ = process.kill() catch {};
        return error.NoResponse;
    };

    std.debug.print("Tool call response received: {s}\n", .{call_response});

    // Clean up
    std.debug.print("Test complete, killing server process...\n", .{});
    _ = process.kill() catch {};

    std.debug.print("Test completed successfully!\n", .{});
}

/// Read from stdout with a timeout
fn readWithTimeout(file: std.fs.File, buf: []u8, timeout_ms: u32) !?[]const u8 {
    const start_time = std.time.milliTimestamp();

    while (std.time.milliTimestamp() - start_time < timeout_ms) {
        // Check if there's data to read without blocking
        var poll_fds = [_]std.posix.pollfd{
            .{
                .fd = file.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
        };

        const available = try std.posix.poll(&poll_fds, 0);
        if (available > 0 and (poll_fds[0].revents & std.posix.POLL.IN) != 0) {
            // Data available, try to read it
            if (try file.reader().readUntilDelimiterOrEof(buf, '\n')) |line| {
                return line;
            } else {
                return null; // EOF
            }
        }

        // Sleep a bit to avoid busy waiting
        std.time.sleep(10 * std.time.ns_per_ms);
    }

    return null; // Timeout
}
