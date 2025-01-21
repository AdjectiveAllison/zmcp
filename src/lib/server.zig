const std = @import("std");
const protocol = @import("protocol.zig");
const tool_mod = @import("tool.zig");
const types = @import("types.zig");

pub const Server = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    version: []const u8,
    tools: std.StringHashMap(tool_mod.ToolInstance),
    min_log_level: std.log.Level,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, version: []const u8) !*Server {
        const self = try allocator.create(Server);
        self.* = .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .version = try allocator.dupe(u8, version),
            .tools = std.StringHashMap(tool_mod.ToolInstance).init(allocator),
            .min_log_level = .info,
        };
        return self;
    }

    pub fn deinit(self: *Server) void {
        self.tools.deinit();
        self.allocator.free(self.name);
        self.allocator.free(self.version);
        self.allocator.destroy(self);
    }

    pub fn addTool(self: *Server, tool: tool_mod.ToolInstance) !void {
        try self.tools.put(tool.name, tool);
    }

    fn handleInitialize(self: *Server, request: protocol.Request) !protocol.Response {
        var obj = std.json.ObjectMap.init(self.allocator);
        try obj.put("protocolVersion", .{ .string = "2024-11-05" });

        var server_info = std.json.ObjectMap.init(self.allocator);
        try server_info.put("name", .{ .string = self.name });
        try server_info.put("version", .{ .string = self.version });
        try obj.put("serverInfo", .{ .object = server_info });

        var capabilities = std.json.ObjectMap.init(self.allocator);

        // Tools capability
        var tools_cap = std.json.ObjectMap.init(self.allocator);
        try tools_cap.put("listChanged", .{ .bool = false }); // We don't support listChanged yet
        try capabilities.put("tools", .{ .object = tools_cap });

        // Logging capability
        const logging_cap = std.json.ObjectMap.init(self.allocator);
        try capabilities.put("logging", .{ .object = logging_cap });

        try obj.put("capabilities", .{ .object = capabilities });

        return protocol.Response.success(request.id, .{ .object = obj });
    }

    fn sendInitialized(stdout: std.fs.File) !void {
        const msg = .{
            .jsonrpc = "2.0",
            .method = "initialized",
            .params = null,
        };
        try std.json.stringify(msg, .{ .emit_null_optional_fields = false }, stdout.writer());
        try stdout.writer().writeByte('\n');
    }

    fn handleToolsList(self: *Server, request: protocol.Request, arena: std.mem.Allocator) !protocol.Response {
        var tools_array = std.json.Array.init(arena);

        var it = self.tools.iterator();
        while (it.next()) |entry| {
            try tools_array.append(entry.value_ptr.toJson(arena));
        }

        // Create the result object without a nextCursor field since we're returning all tools at once
        var result_obj = std.json.ObjectMap.init(arena);
        try result_obj.put("tools", .{ .array = tools_array });
        // Note: We don't add nextCursor at all when there are no more results

        return protocol.Response.success(request.id, .{ .object = result_obj });
    }

    fn handleToolCall(self: *Server, request: protocol.Request, arena: std.mem.Allocator) !protocol.Response {
        const params = request.params orelse
            return protocol.Response.failure(request.id, protocol.ErrorCode.InvalidParams, "Missing parameters");

        // Extract tool name and arguments
        const tool_name = if (params.object.get("name")) |n| n.string else return protocol.Response.failure(request.id, protocol.ErrorCode.InvalidParams, "Missing tool name");

        const tool = self.tools.get(tool_name) orelse
            return protocol.Response.failure(request.id, protocol.ErrorCode.MethodNotFound, "Tool not found");

        const args = params.object.get("arguments") orelse
            return protocol.Response.failure(request.id, protocol.ErrorCode.InvalidParams, "Missing arguments");

        // Handle progress token if provided
        const stdout_for_progress = std.io.getStdOut();
        const progress_token = if (params.object.get("progressToken")) |t| t else null;
        if (progress_token != null) {
            // Send initial progress notification
            try self.sendProgress(stdout_for_progress, progress_token.?, 0, null);
        }

        // Execute the tool
        const result = tool.call(args);

        if (progress_token != null) {
            // Send completion progress notification
            try self.sendProgress(stdout_for_progress, progress_token.?, 100, 100);
        }

        // Create success response object with the result in the expected format
        var content_array = std.json.Array.init(arena);

        var text_obj = std.json.ObjectMap.init(arena);
        try text_obj.put("type", .{ .string = "text" });
        try text_obj.put("text", result);

        try content_array.append(.{ .object = text_obj });

        var result_obj = std.json.ObjectMap.init(arena);
        try result_obj.put("isError", .{ .bool = false });
        try result_obj.put("content", .{ .array = content_array });

        return protocol.Response.success(request.id, .{ .object = result_obj });
    }

    fn sendProgress(self: *Server, stdout: std.fs.File, token: protocol.Value, progress: f64, total: ?f64) !void {
        _ = self; // autofix
        const msg = .{
            .jsonrpc = "2.0",
            .method = "$/progress",
            .params = .{
                .token = token,
                .progress = progress,
                .total = total,
            },
        };
        try std.json.stringify(msg, .{ .emit_null_optional_fields = true }, stdout.writer());
        try stdout.writer().writeByte('\n');
    }

    pub fn start(self: *Server) !void {
        const stdin = std.io.getStdIn();
        const stdout = std.io.getStdOut();
        const debug_file = try std.fs.cwd().createFile("debug.log", .{});
        defer debug_file.close();

        var is_initialized = false;
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        var arena = arena_state.allocator();

        while (true) {
            arena_state = std.heap.ArenaAllocator.init(self.allocator);
            defer arena_state.deinit();
            arena = arena_state.allocator();

            // Read a line
            var buf: [4096]u8 = undefined;
            if (try stdin.reader().readUntilDelimiterOrEof(&buf, '\n')) |line| {
                // Debug: log received message
                try debug_file.writer().print("Received: {s}\n", .{line});

                // Parse JSON message
                const parsed = try std.json.parseFromSlice(
                    std.json.Value,
                    arena,
                    line,
                    .{},
                );

                const request = try protocol.Request.fromJson(parsed.value);

                // Handle notifications differently from requests
                if (request.isNotification()) {
                    try self.handleNotification(request);
                    continue;
                }

                var response: protocol.Response = undefined;

                if (std.mem.eql(u8, request.method, "initialize")) {
                    response = try self.handleInitialize(request);
                    // Send initialized notification after successful initialization
                    if (!is_initialized) {
                        try sendInitialized(stdout);
                        is_initialized = true;
                    }
                } else if (!is_initialized) {
                    response = protocol.Response.failure(request.id, protocol.ErrorCode.ServerNotInitialized, "Server not initialized");
                } else if (std.mem.eql(u8, request.method, "tools/list")) {
                    response = try self.handleToolsList(request, arena);
                } else if (std.mem.eql(u8, request.method, "tools/call")) {
                    response = try self.handleToolCall(request, arena);
                } else if (std.mem.eql(u8, request.method, "logging/setLevel")) {
                    response = try self.handleLogging(request);
                } else {
                    response = protocol.Response.failure(request.id, protocol.ErrorCode.MethodNotFound, "Method not found");
                }

                // Debug: log response before sending
                var response_json = std.ArrayList(u8).init(arena);
                try std.json.stringify(response, .{ .emit_null_optional_fields = false }, response_json.writer());
                try debug_file.writer().print("Sending: {s}\n", .{response_json.items});

                // Write response
                try std.json.stringify(response, .{ .emit_null_optional_fields = false }, stdout.writer());
                try stdout.writer().writeByte('\n');
            }
        }
    }

    fn handleNotification(self: *Server, request: protocol.Request) !void {
        _ = self;
        if (std.mem.eql(u8, request.method, "notifications/initialized")) {
            // Client is telling us it's ready to receive requests
            return;
        }
        // Add other notification handlers here as needed
    }

    fn handleLogging(self: *Server, request: protocol.Request) !protocol.Response {
        const params = request.params orelse
            return protocol.Response.failure(request.id, protocol.ErrorCode.InvalidParams, "Missing parameters");

        const level = if (params.object.get("level")) |l| l.string else return protocol.Response.failure(request.id, protocol.ErrorCode.InvalidParams, "Missing log level");

        self.min_log_level = std.meta.stringToEnum(std.log.Level, level) orelse
            return protocol.Response.failure(request.id, protocol.ErrorCode.InvalidParams, "Invalid log level");

        return protocol.Response.success(request.id, .{ .null = {} });
    }
};
