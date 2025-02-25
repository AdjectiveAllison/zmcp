const std = @import("std");
const protocol = @import("protocol.zig");
const types = @import("types.zig");

// Debug helper function to print ID values in detail
fn debugPrintId(prefix: []const u8, id: protocol.Value) void {
    std.debug.print("{s} ID type: {s}, ", .{ prefix, @tagName(id) });
    
    switch (id) {
        .integer => std.debug.print("value: {}\n", .{id.integer}),
        .string => std.debug.print("value: \"{s}\"\n", .{id.string}),
        else => std.debug.print("unexpected type\n", .{}),
    }
}

// Enhanced ID comparison function
fn compareIds(a: protocol.Value, b: protocol.Value) bool {
    // Direct match
    if (protocol.valuesEqual(a, b)) return true;
    
    // Handle integer-string conversions
    if (a == .integer and b == .string) {
        // Convert integer to string and compare
        var buf: [20]u8 = undefined; // Enough for any i64
        const str = std.fmt.bufPrint(&buf, "{d}", .{a.integer}) catch return false;
        return std.mem.eql(u8, str, b.string);
    }
    
    if (a == .string and b == .integer) {
        // Convert integer to string and compare
        var buf: [20]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "{d}", .{b.integer}) catch return false;
        return std.mem.eql(u8, str, a.string);
    }
    
    return false;
}

pub const InitializeOptions = struct {
    name: []const u8,
    version: []const u8,
    // If true, include sampling capability
    enable_sampling: bool = false,
    // If true, include roots capability
    enable_roots: bool = false,
};

pub const CallOptions = struct {
    // If provided, will be used for progress notifications
    progress_token: ?protocol.Value = null,
    // Optional timeout in milliseconds
    timeout_ms: ?u32 = null,
};

pub const ToolResult = struct {
    is_error: bool,
    content: []protocol.Value,

    pub fn deinit(self: *ToolResult, allocator: std.mem.Allocator) void {
        // Free each content item
        for (self.content) |*value| {
            // Clean up any allocations in this value
            protocol.cleanupValue(allocator, value);
        }
        allocator.free(self.content);
    }
};

const CapabilityInfo = struct {
    tools: bool = false,
    tools_list_changed: bool = false,
    resources: bool = false,
    resources_subscribe: bool = false,
    resources_list_changed: bool = false,
    prompts: bool = false,
    prompts_list_changed: bool = false,
    logging: bool = false,
};

pub const CallbackContext = struct {
    allocator: std.mem.Allocator,
    on_progress: ?*const fn (token: protocol.Value, progress: f64, total: ?f64, context: ?*anyopaque) void = null,
    on_log: ?*const fn (level: []const u8, message: []const u8, context: ?*anyopaque) void = null,
    on_tools_changed: ?*const fn (context: ?*anyopaque) void = null,
    on_resources_changed: ?*const fn (context: ?*anyopaque) void = null,
    on_prompts_changed: ?*const fn (context: ?*anyopaque) void = null,
    user_context: ?*anyopaque = null,
};

const TransportType = enum {
    Stdio,
    Http,
};

const Transport = union(TransportType) {
    Stdio: struct {
        process: ?std.process.Child = null,
        stdin: std.fs.File,
        stdout: std.fs.File,
    },
    Http: struct {
        // Not implemented yet, placeholders for future expansion
        endpoint: []const u8,
        sse_connection: ?*anyopaque = null,
    },
};

const RequestState = struct {
    id: protocol.Value,
    completed: bool = false,
    response: ?protocol.Response = null,
    allocator: std.mem.Allocator,
    progress_token: ?protocol.Value = null,
    on_progress: ?*const fn (token: protocol.Value, progress: f64, total: ?f64, context: ?*anyopaque) void = null,
    user_context: ?*anyopaque = null,

    pub fn deinit(self: *RequestState) void {
        // Clean up response if present
        if (self.response) |*resp| {
            protocol.deinitResponse(self.allocator, resp);
        }
        
        // Clean up ID
        if (self.id == .string) {
            self.allocator.free(self.id.string);
        }
        
        // Clean up progress token
        if (self.progress_token) |*token| {
            protocol.cleanupValue(self.allocator, token);
        }
    }
};

pub const ClientBuilder = struct {
    allocator: std.mem.Allocator,
    name: []const u8 = "MCP Client",
    version: []const u8 = "1.0.0",
    transport_type: TransportType = .Stdio,
    command: ?[]const u8 = null,
    args: ?[]const []const u8 = null,
    http_endpoint: ?[]const u8 = null,
    enable_debug: bool = false,
    on_progress: ?*const fn (token: protocol.Value, progress: f64, total: ?f64, context: ?*anyopaque) void = null,
    on_log: ?*const fn (level: []const u8, message: []const u8, context: ?*anyopaque) void = null,
    on_tools_changed: ?*const fn (context: ?*anyopaque) void = null,
    on_resources_changed: ?*const fn (context: ?*anyopaque) void = null,
    on_prompts_changed: ?*const fn (context: ?*anyopaque) void = null,
    user_context: ?*anyopaque = null,
    enable_sampling: bool = false,
    enable_roots: bool = false,

    pub fn init(allocator: std.mem.Allocator) ClientBuilder {
        return .{
            .allocator = allocator,
        };
    }

    pub fn withName(self: ClientBuilder, name: []const u8) ClientBuilder {
        var result = self;
        result.name = name;
        return result;
    }

    pub fn withVersion(self: ClientBuilder, version: []const u8) ClientBuilder {
        var result = self;
        result.version = version;
        return result;
    }

    pub fn withCommand(self: ClientBuilder, command: []const u8, args: ?[]const []const u8) ClientBuilder {
        var result = self;
        result.transport_type = .Stdio;
        result.command = command;
        result.args = args;
        return result;
    }

    pub fn withHttpEndpoint(self: ClientBuilder, endpoint: []const u8) ClientBuilder {
        var result = self;
        result.transport_type = .Http;
        result.http_endpoint = endpoint;
        return result;
    }

    pub fn withStdio(self: ClientBuilder) ClientBuilder {
        var result = self;
        result.transport_type = .Stdio;
        result.command = null;
        result.args = null;
        return result;
    }

    pub fn withDebugLogging(self: ClientBuilder, enable: bool) ClientBuilder {
        var result = self;
        result.enable_debug = enable;
        return result;
    }

    pub fn withProgressHandler(self: ClientBuilder, handler: *const fn (token: protocol.Value, progress: f64, total: ?f64, context: ?*anyopaque) void) ClientBuilder {
        var result = self;
        result.on_progress = handler;
        return result;
    }

    pub fn withLogHandler(self: ClientBuilder, handler: *const fn (level: []const u8, message: []const u8, context: ?*anyopaque) void) ClientBuilder {
        var result = self;
        result.on_log = handler;
        return result;
    }

    pub fn withToolsChangedHandler(self: ClientBuilder, handler: *const fn (context: ?*anyopaque) void) ClientBuilder {
        var result = self;
        result.on_tools_changed = handler;
        return result;
    }

    pub fn withResourcesChangedHandler(self: ClientBuilder, handler: *const fn (context: ?*anyopaque) void) ClientBuilder {
        var result = self;
        result.on_resources_changed = handler;
        return result;
    }

    pub fn withPromptsChangedHandler(self: ClientBuilder, handler: *const fn (context: ?*anyopaque) void) ClientBuilder {
        var result = self;
        result.on_prompts_changed = handler;
        return result;
    }

    pub fn withUserContext(self: ClientBuilder, context: ?*anyopaque) ClientBuilder {
        var result = self;
        result.user_context = context;
        return result;
    }

    pub fn withSamplingEnabled(self: ClientBuilder, enable: bool) ClientBuilder {
        var result = self;
        result.enable_sampling = enable;
        return result;
    }

    pub fn withRootsEnabled(self: ClientBuilder, enable: bool) ClientBuilder {
        var result = self;
        result.enable_roots = enable;
        return result;
    }

    pub fn build(self: ClientBuilder) !*Client {
        // Create callback context
        const callback_context = CallbackContext{
            .allocator = self.allocator,
            .on_progress = self.on_progress,
            .on_log = self.on_log,
            .on_tools_changed = self.on_tools_changed,
            .on_resources_changed = self.on_resources_changed,
            .on_prompts_changed = self.on_prompts_changed,
            .user_context = self.user_context,
        };

        // Create client instance
        const client = try Client.init(self.allocator, callback_context);
        errdefer client.deinit();

        // Setup debug logging if requested
        if (self.enable_debug) {
            try client.enableDebugLogging();
        }

        // Setup transport based on type
        switch (self.transport_type) {
            .Stdio => {
                if (self.command) |cmd| {
                    const args = self.args orelse &[_][]const u8{};
                    try client.connectToCommand(cmd, args);
                } else {
                    try client.connectToStdio();
                }
            },
            .Http => {
                if (self.http_endpoint) |_| {
                    // HTTP transport not implemented yet, this is a placeholder
                    return error.HttpTransportNotImplemented;
                } else {
                    return error.InvalidHttpEndpoint;
                }
            },
        }

        // Initialize the client
        try client.initialize(.{
            .name = self.name,
            .version = self.version,
            .enable_sampling = self.enable_sampling,
            .enable_roots = self.enable_roots,
        });

        return client;
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    transport: Transport,
    initialized: bool = false,
    server_info: struct {
        name: []const u8 = "",
        version: []const u8 = "",
    } = .{},
    protocol_version: []const u8 = "2024-11-05",
    capabilities: CapabilityInfo = .{},
    next_id: u32 = 1,
    pending_requests: std.ArrayList(RequestState),
    message_queue: std.ArrayList(protocol.Response),
    callback_context: CallbackContext,
    debug_file: ?std.fs.File = null,

    pub fn init(allocator: std.mem.Allocator, callback_context: CallbackContext) !*Client {
        const self = try allocator.create(Client);
        self.* = .{
            .allocator = allocator,
            .transport = undefined, // Will be set by connectToCommand or other connect methods
            .pending_requests = std.ArrayList(RequestState).init(allocator),
            .message_queue = std.ArrayList(protocol.Response).init(allocator),
            .callback_context = callback_context,
        };
        return self;
    }

    pub fn builder(allocator: std.mem.Allocator) ClientBuilder {
        return ClientBuilder.init(allocator);
    }

    pub fn deinit(self: *Client) void {
        // Clean up pending requests
        for (self.pending_requests.items) |*req| {
            req.deinit();
        }
        self.pending_requests.deinit();
        
        // Clean up message queue
        for (self.message_queue.items) |*msg| {
            protocol.deinitResponse(self.allocator, msg);
        }
        self.message_queue.deinit();

        // Clean up transport
        switch (self.transport) {
            .Stdio => |*stdio| {
                if (stdio.process) |*process| {
                    _ = process.kill() catch {};
                    // If we created the process, we should close its handles
                    if (process.stdin) |stdin| {
                        stdin.close();
                    }
                    if (process.stdout) |stdout| {
                        stdout.close();
                    }
                    if (process.stderr) |stderr| {
                        stderr.close();
                    }
                }
            },
            .Http => |*http| {
                if (http.endpoint.len > 0) {
                    self.allocator.free(http.endpoint);
                }
            },
        }

        // Clean up server info
        if (self.server_info.name.len > 0) {
            self.allocator.free(self.server_info.name);
        }
        if (self.server_info.version.len > 0) {
            self.allocator.free(self.server_info.version);
        }

        // Clean up protocol version if it's not the default
        if (self.protocol_version.ptr != "2024-11-05".ptr) {
            self.allocator.free(self.protocol_version);
        }

        if (self.debug_file) |*file| {
            file.close();
        }

        self.allocator.destroy(self);
    }

    pub fn enableDebugLogging(self: *Client) !void {
        if (self.debug_file == null) {
            self.debug_file = try std.fs.cwd().createFile("client_debug.log", .{});
        }
    }

    pub fn connectToCommand(self: *Client, command: []const u8, args: []const []const u8) !void {
        var process_args = std.ArrayList([]const u8).init(self.allocator);
        defer process_args.deinit();

        try process_args.append(command);
        for (args) |arg| {
            try process_args.append(arg);
        }

        var process = std.process.Child.init(process_args.items, self.allocator);
        process.stdin_behavior = .Pipe;
        process.stdout_behavior = .Pipe;
        process.stderr_behavior = .Pipe;

        try process.spawn();

        self.transport = .{
            .Stdio = .{
                .process = process,
                .stdin = process.stdin.?,
                .stdout = process.stdout.?,
            },
        };
    }

    pub fn connectToStdio(self: *Client) !void {
        self.transport = .{
            .Stdio = .{
                .process = null,
                .stdin = std.io.getStdOut(),
                .stdout = std.io.getStdIn(),
            },
        };
    }

    fn buildCommandArgs(allocator: std.mem.Allocator, command: []const u8, args: []const []const u8) ![]const []const u8 {
        var argv = try std.ArrayList([]const u8).initCapacity(allocator, args.len + 1);
        try argv.append(command);
        for (args) |arg| {
            try argv.append(arg);
        }
        return argv.toOwnedSlice();
    }

    pub fn initialize(self: *Client, options: InitializeOptions) !void {
        std.debug.print("Client initializing...\n", .{});

        // Create an arena for temporary allocations
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        // Create capabilities object using arena
        var capabilities = std.json.ObjectMap.init(arena);

        if (options.enable_sampling) {
            const sampling_obj = std.json.ObjectMap.init(arena);
            try capabilities.put("sampling", .{ .object = sampling_obj });
        }

        if (options.enable_roots) {
            const roots_obj = std.json.ObjectMap.init(arena);
            try capabilities.put("roots", .{ .object = roots_obj });
        }

        // Create client info object using arena
        var client_info = std.json.ObjectMap.init(arena);

        const name_copy = try arena.dupe(u8, options.name);
        try client_info.put("name", .{ .string = name_copy });

        const version_copy = try arena.dupe(u8, options.version);
        try client_info.put("version", .{ .string = version_copy });

        // Create params using arena
        var params = std.json.ObjectMap.init(arena);

        const protocol_copy = try arena.dupe(u8, self.protocol_version);
        try params.put("protocolVersion", .{ .string = protocol_copy });

        // Add objects to params (no need to clone since they're all in the arena)
        try params.put("capabilities", .{ .object = capabilities });
        try params.put("clientInfo", .{ .object = client_info });

        // Send initialize request
        const id = self.nextId();
        std.debug.print("Sending initialize request with id: {}\n", .{id.integer});
        try self.sendRequest("initialize", .{ .object = params }, id);

        // Wait for response
        std.debug.print("Waiting for initialize response...\n", .{});
        const response = try self.waitForResponseSimple(id);
        std.debug.print("Received initialize response\n", .{});

        try self.processInitializeResponse(response);

        // Send initialized notification
        std.debug.print("Sending initialized notification\n", .{});
        try self.sendNotification("initialized", null);

        self.initialized = true;
        std.debug.print("Client initialization complete\n", .{});
    }

    fn processInitializeResponse(self: *Client, response: protocol.Response) !void {
        if (response.@"error" != null) {
            return error.InitializationFailed;
        }

        const result = response.result orelse return error.InitializationFailed;
        if (result != .object) return error.InitializationFailed;

        // Extract server information
        if (result.object.get("serverInfo")) |server_info| {
            if (server_info == .object) {
                if (server_info.object.get("name")) |name| {
                    if (name == .string) {
                        self.server_info.name = try self.allocator.dupe(u8, name.string);
                    }
                }
                if (server_info.object.get("version")) |version| {
                    if (version == .string) {
                        self.server_info.version = try self.allocator.dupe(u8, version.string);
                    }
                }
            }
        }

        // Extract protocol version
        if (result.object.get("protocolVersion")) |version| {
            if (version == .string) {
                // Free previous value if it's not the default
                if (self.protocol_version.ptr != "2024-11-05".ptr) {
                    self.allocator.free(self.protocol_version);
                }
                self.protocol_version = try self.allocator.dupe(u8, version.string);
            }
        }

        // Extract capabilities
        if (result.object.get("capabilities")) |caps| {
            if (caps == .object) {
                // Check for tools capability
                if (caps.object.get("tools")) |tools| {
                    if (tools == .object) {
                        self.capabilities.tools = true;
                        if (tools.object.get("listChanged")) |list_changed| {
                            if (list_changed == .bool) {
                                self.capabilities.tools_list_changed = list_changed.bool;
                            }
                        }
                    }
                }

                // Check for resources capability
                if (caps.object.get("resources")) |resources| {
                    if (resources == .object) {
                        self.capabilities.resources = true;
                        if (resources.object.get("subscribe")) |subscribe| {
                            if (subscribe == .bool) {
                                self.capabilities.resources_subscribe = subscribe.bool;
                            }
                        }
                        if (resources.object.get("listChanged")) |list_changed| {
                            if (list_changed == .bool) {
                                self.capabilities.resources_list_changed = list_changed.bool;
                            }
                        }
                    }
                }

                // Check for prompts capability
                if (caps.object.get("prompts")) |prompts| {
                    if (prompts == .object) {
                        self.capabilities.prompts = true;
                        if (prompts.object.get("listChanged")) |list_changed| {
                            if (list_changed == .bool) {
                                self.capabilities.prompts_list_changed = list_changed.bool;
                            }
                        }
                    }
                }

                // Check for logging capability
                if (caps.object.get("logging")) |logging| {
                    if (logging == .object) {
                        self.capabilities.logging = true;
                    }
                }
            }
        }
    }

    pub fn listTools(self: *Client) ![]protocol.Value {
        if (!self.capabilities.tools) {
            return error.ServerDoesNotSupportTools;
        }

        const id = self.nextId();
        try self.sendRequest("tools/list", null, id);

        const response = try self.waitForResponseSimple(id);
        if (response.@"error" != null) {
            return error.ListToolsFailed;
        }

        const result = response.result orelse return error.ListToolsFailed;
        if (result != .object) return error.ListToolsFailed;

        const tools = result.object.get("tools") orelse return error.ListToolsFailed;
        if (tools != .array) return error.ListToolsFailed;

        // Make a copy of the tools array
        var tools_copy = try std.ArrayList(protocol.Value).initCapacity(
            self.allocator,
            tools.array.items.len,
        );
        for (tools.array.items) |tool| {
            try tools_copy.append(try protocol.cloneValue(self.allocator, tool));
        }

        return tools_copy.toOwnedSlice();
    }

    /// Simplified version of callTool that returns a specific type
    pub fn callToolAs(
        self: *Client,
        comptime ResultType: type,
        name: []const u8,
        args: anytype,
        options: CallOptions,
    ) !ResultType {
        var result = try self.callTool(name, args, options);
        defer result.deinit(self.allocator);

        if (result.is_error) {
            return error.ToolCallFailed;
        }

        if (result.content.len == 0) {
            return error.ToolCallInvalidResult;
        }

        // Find text content
        for (result.content) |content| {
            if (content != .object) continue;

            const content_type = content.object.get("type") orelse continue;
            if (content_type != .string) continue;

            if (std.mem.eql(u8, content_type.string, "text")) {
                const text = content.object.get("text") orelse continue;
                if (text != .string) continue;

                // For string result type
                if (ResultType == []const u8) {
                    return self.allocator.dupe(u8, text.string);
                }

                // For integer result type
                if (ResultType == i64 or ResultType == i32 or ResultType == i16 or ResultType == i8) {
                    return std.fmt.parseInt(ResultType, text.string, 10) catch return error.ToolCallInvalidResult;
                }

                // For unsigned result type
                if (ResultType == u64 or ResultType == u32 or ResultType == u16 or ResultType == u8) {
                    return std.fmt.parseInt(ResultType, text.string, 10) catch return error.ToolCallInvalidResult;
                }

                // For float result type
                if (ResultType == f64 or ResultType == f32) {
                    return std.fmt.parseFloat(ResultType, text.string) catch return error.ToolCallInvalidResult;
                }

                // For boolean result type
                if (ResultType == bool) {
                    if (std.mem.eql(u8, text.string, "true")) {
                        return true;
                    } else if (std.mem.eql(u8, text.string, "false")) {
                        return false;
                    } else {
                        return error.ToolCallInvalidResult;
                    }
                }

                // For complex types, we'd implement JSON parsing
                // This is simplified and would need expansion for struct types
            }
        }

        return error.ToolCallInvalidResult;
    }

    /// Calls a tool and returns the text response
    pub fn callToolText(
        self: *Client,
        name: []const u8,
        args: anytype,
        options: CallOptions,
    ) ![]const u8 {
        return self.callToolAs([]const u8, name, args, options);
    }

    /// Main tool call method
    pub fn callTool(
        self: *Client,
        name: []const u8,
        args: anytype,
        options: CallOptions,
    ) !ToolResult {
        if (!self.capabilities.tools) {
            return error.ServerDoesNotSupportTools;
        }
        std.debug.print("Sending tool call to: {s}\n", .{name});

        // Create an arena for temporary allocations
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        // Create params using arena
        var params = std.json.ObjectMap.init(arena);

        // Copy name to arena
        const name_copy = try arena.dupe(u8, name);
        try params.put("name", .{ .string = name_copy });

        // Handle arguments based on type
        const Args = @TypeOf(args);
        if (@typeInfo(Args) == .Struct) {
            // Create an object for the arguments using arena
            var args_obj = std.json.ObjectMap.init(arena);

            inline for (std.meta.fields(Args)) |field| {
                const field_value = @field(args, field.name);

                // Handle each field based on its type
                switch (@TypeOf(field_value)) {
                    []const u8 => {
                        const str_copy = try arena.dupe(u8, field_value);
                        try args_obj.put(field.name, .{ .string = str_copy });
                    },
                    comptime_int, i8, i16, i32, i64, isize => try args_obj.put(field.name, .{ .integer = field_value }),
                    u8, u16, u32, u64, usize => try args_obj.put(field.name, .{ .integer = @intCast(field_value) }),
                    f32, f64 => try args_obj.put(field.name, .{ .float = field_value }),
                    bool => try args_obj.put(field.name, .{ .bool = field_value }),
                    else => {
                        // For non-primitive types, just use a string representation
                        const str_repr = try std.fmt.allocPrint(arena, "{any}", .{field_value});
                        try args_obj.put(field.name, .{ .string = str_repr });
                    },
                }
            }

            try params.put("arguments", .{ .object = args_obj });
        } else {
            // If not a struct, convert directly to a string
            const str_repr = try std.fmt.allocPrint(arena, "{any}", .{args});
            try params.put("arguments", .{ .string = str_repr });
        }

        // Add progress token if provided - these need to be persistent
        var progress_token_copy: ?protocol.Value = null;
        if (options.progress_token) |token| {
            // Clone to permanent storage for the request state
            progress_token_copy = try protocol.cloneValue(self.allocator, token);
            // Use arena for the request itself
            try params.put("progressToken", try protocol.cloneValue(arena, token));
        }

        // Create a unique ID for this request
        const id = self.nextId();
        
        // Create request state with progress handling info - this is persistent storage
        const req_state = RequestState{
            .id = id,
            .allocator = self.allocator,
            .progress_token = if (progress_token_copy) |token| try protocol.cloneValue(self.allocator, token) else null,
            .on_progress = self.callback_context.on_progress,
            .user_context = self.callback_context.user_context,
        };

        // Add to pending requests here, sendRequest will detect and avoid double-adding
        try self.pending_requests.append(req_state);
        std.debug.print("Added tool call request to pending_requests\n", .{});

        const params_value = protocol.Value{ .object = params };
        try self.sendRequest("tools/call", params_value, id);

        // Wait for response with proper timeout handling
        var response = try self.waitForResponse(id, options.timeout_ms);

        if (response.@"error" != null) {
            protocol.deinitResponse(self.allocator, &response);
            return error.ToolCallFailed;
        }

        const result = response.result orelse {
            protocol.deinitResponse(self.allocator, &response);
            return error.ToolCallFailed;
        };
        
        if (result != .object) {
            protocol.deinitResponse(self.allocator, &response);
            return error.ToolCallFailed;
        }

        const is_error = if (result.object.get("isError")) |err| (err == .bool and err.bool) else false;

        const content = result.object.get("content") orelse {
            protocol.deinitResponse(self.allocator, &response);
            return error.ToolCallFailed;
        };
        
        if (content != .array) {
            protocol.deinitResponse(self.allocator, &response);
            return error.ToolCallFailed;
        }

        // Make a copy of the content array
        var content_copy = try std.ArrayList(protocol.Value).initCapacity(
            self.allocator,
            content.array.items.len,
        );

        for (content.array.items) |item| {
            try content_copy.append(try protocol.cloneValue(self.allocator, item));
        }

        // Clean up response now that we've extracted what we need
        protocol.deinitResponse(self.allocator, &response);

        return ToolResult{
            .is_error = is_error,
            .content = try content_copy.toOwnedSlice(),
        };
    }

    /// Wait for a response with an optional timeout
    fn waitForResponse(self: *Client, id: protocol.Value, timeout_ms: ?u32) !protocol.Response {
        std.debug.print("waitForResponse: Looking for ", .{});
        debugPrintId("", id);
        
        // Don't create a new request state as the calling function should have already created one
        var timer: ?std.time.Timer = null;
        if (timeout_ms != null) {
            timer = try std.time.Timer.start();
        }
        
        // Debug: show current queue and pending requests
        std.debug.print("Current queue size: {d}\n", .{self.message_queue.items.len});
        std.debug.print("Current pending requests: {d}\n", .{self.pending_requests.items.len});
        
        // First check if we already have this response in our queue
        for (self.message_queue.items, 0..) |*resp, index| {
            // Skip responses with null IDs (shouldn't happen per protocol but being defensive)
            if (resp.id == null) continue;
            
            debugPrintId("Checking queued response", resp.id.?);
            
            const matches = compareIds(resp.id.?, id);
            std.debug.print("Queue item {d} matches: {}\n", .{index, matches});
            
            if (matches) {
                // Found it in the queue, remove and return it
                std.debug.print("✅ Found response in queue for ", .{});
                debugPrintId("", id);
                
                // Make a copy for the caller
                const response_copy = try protocol.cloneResponse(self.allocator, resp.*);
                
                // Clean up and remove the queued response
                protocol.deinitResponse(self.allocator, resp);
                _ = self.message_queue.orderedRemove(index);
                
                return response_copy;
            }
        }
        
        // Process any messages that are immediately available
        try self.processAvailable();
        
        // Check if our specific request is now completed
        for (self.pending_requests.items, 0..) |req, index| {
            std.debug.print("After processing, checking pending request at index {}: ", .{index});
            debugPrintId("", req.id);
            
            if (compareIds(req.id, id) and req.completed) {
                std.debug.print("✅ waitForResponse: request ID is now completed\n", .{});
                const response = req.response.?;
                
                // Make a copy of the response before removing the request state
                const response_copy = try protocol.cloneResponse(self.allocator, response);
                
                // Make a copy of the request state before swapRemove
                var req_copy = req;
                
                // Remove from pending requests
                _ = self.pending_requests.swapRemove(index);
                
                // Clean up the request state
                req_copy.deinit();
                
                return response_copy;
            }
        }
        
        // Create an arena for the timeout handling
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        
        // Main waiting loop
        var loops: u32 = 0;
        while (true) {
            loops += 1;
            if (loops % 1000 == 0) {
                std.debug.print("waitForResponse: still waiting after {} loops for ID {}\n", .{
                    loops,
                    if (id == .integer) id.integer else @as(i64, 0)
                });
            }
            
            // Process any incoming messages
            try self.processOneMessage();
            
            // Check if our request has completed
            for (self.pending_requests.items, 0..) |req, index| {
                if (protocol.valuesEqual(req.id, id) and req.completed) {
                    std.debug.print("waitForResponse: found completed request after {} loops\n", .{loops});
                    const response = req.response.?;
                    
                    // Make a copy of the response before removing the request state
                    const response_copy = try protocol.cloneResponse(self.allocator, response);
                    
                    // Make a copy of the request state before swapRemove
                    var req_copy = req;
                    
                    // Remove from pending requests
                    _ = self.pending_requests.swapRemove(index);
                    
                    // Clean up the request state
                    req_copy.deinit();
                    
                    return response_copy;
                }
            }
            
            // Check timeout
            if (timer) |*t| {
                if (timeout_ms.? <= t.read() / std.time.ns_per_ms) {
                    std.debug.print("waitForResponse: timeout exceeded\n", .{});
                    
                    // Send cancellation using arena for temporary objects
                    var cancel_params = std.json.ObjectMap.init(arena);
                    try cancel_params.put("id", try protocol.cloneValue(arena, id));
                    try cancel_params.put("reason", .{ .string = "Timeout exceeded" });
                    
                    try self.sendNotification("notifications/cancelled", .{ .object = cancel_params });
                    return error.Timeout;
                }
            }
            
            // Yield to avoid busy waiting
            std.time.sleep(1 * std.time.ns_per_ms);
        }
        
        // This should never be reached, but needed to satisfy the compiler
        return error.ResponseNotReceived;
    }

    pub fn setLogLevel(self: *Client, level: []const u8) !void {
        if (!self.capabilities.logging) {
            return error.ServerDoesNotSupportLogging;
        }

        var params = std.json.ObjectMap.init(self.allocator);
        try params.put("level", .{ .string = try self.allocator.dupe(u8, level) });

        const id = self.nextId();
        try self.sendRequest("logging/setLevel", .{ .object = params }, id);

        const response = try self.waitForResponseSimple(id);
        if (response.@"error" != null) {
            return error.SetLogLevelFailed;
        }
    }

    pub fn processMessages(self: *Client) !void {
        while (try self.hasMessages()) {
            try self.processOneMessage();
        }
    }
    
    pub fn processAvailable(self: *Client) !void {
        // Read and process any available messages without blocking
        while (true) {
            const message = try self.readMessage();
            if (message.len == 0) break; // No more messages available
            
            defer self.allocator.free(message);
            std.debug.print("Processing message: {s}\n", .{message});
            
            const parsed = try std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                message,
                .{},
            );
            defer parsed.deinit();
            
            const json = parsed.value;
            
            if (protocol.isResponse(json)) {
                try self.handleResponse(json, null);
            } else if (protocol.isNotification(json)) {
                try self.handleNotification(json, null);
            } else if (protocol.isRequest(json)) {
                try self.handleRequest(json, null);
            }
        }
    }

    fn hasMessages(self: *Client) !bool {
        switch (self.transport) {
            .Stdio => |stdio| {
                // Check if there's data available on stdout without blocking
                var poll_fds = [_]std.posix.pollfd{
                    .{
                        .fd = stdio.stdout.handle,
                        .events = std.posix.POLL.IN,
                        .revents = 0,
                    },
                };

                const available = try std.posix.poll(&poll_fds, 0);
                return available > 0 and (poll_fds[0].revents & std.posix.POLL.IN) != 0;
            },
            .Http => {
                // Not implemented
                return false;
            },
        }
    }

    fn processOneMessage(self: *Client) !void {
        // Create an arena for temporary allocations
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        
        // Read message using the client's allocator (still needs explicit free)
        const message = try self.readMessage();
        defer if (message.len > 0) self.allocator.free(message);
        if (message.len == 0) return;
        
        // Debug log
        std.debug.print("processOneMessage: Received message of length {}\n", .{message.len});
        if (self.debug_file) |file| {
            try file.writer().print("Received: {s}\n", .{message});
        }
        
        // Parse using arena - no need to clean up parsed
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            arena,
            message,
            .{},
        );
        const json = parsed.value;
        
        // Process message based on type, passing arena to handlers
        if (protocol.isResponse(json)) {
            std.debug.print("processOneMessage: Handling response\n", .{});
            try self.handleResponse(json, arena);
        } else if (protocol.isNotification(json)) {
            std.debug.print("processOneMessage: Handling notification\n", .{});
            try self.handleNotification(json, arena);
        } else if (protocol.isRequest(json)) {
            std.debug.print("processOneMessage: Handling request\n", .{});
            try self.handleRequest(json, arena);
        } else {
            // Invalid message
            std.debug.print("processOneMessage: Invalid message format\n", .{});
            if (self.debug_file) |file| {
                try file.writer().print("Invalid message format: {s}\n", .{message});
            }
        }
    }

    fn readMessage(self: *Client) ![]const u8 {
        switch (self.transport) {
            .Stdio => |stdio| {
                // Poll for data
                var poll_fds = [_]std.posix.pollfd{
                    .{
                        .fd = stdio.stdout.handle,
                        .events = std.posix.POLL.IN,
                        .revents = 0,
                    },
                };
                
                const available = try std.posix.poll(&poll_fds, 0); // 0 = non-blocking
                const has_input = (available > 0) and ((poll_fds[0].revents & std.posix.POLL.IN) != 0);
                
                if (!has_input) {
                    // No data available
                    return &[_]u8{};
                }
                
                // Data available, read it
                var buf: [8192]u8 = undefined;
                if (try stdio.stdout.reader().readUntilDelimiterOrEof(&buf, '\n')) |line| {
                    std.debug.print("readMessage: Read {} bytes\n", .{line.len});
                    return try self.allocator.dupe(u8, line);
                } else {
                    // EOF reached
                    std.debug.print("readMessage: EOF reached\n", .{});
                    return &[_]u8{};
                }
            },
            .Http => {
                // Not implemented
                return &[_]u8{};
            },
        }
    }

    fn handleResponse(self: *Client, json: protocol.Value, arena_opt: ?std.mem.Allocator) !void {
        // Extract ID
        const id = json.object.get("id") orelse return;
        
        std.debug.print("Response received with ", .{});
        debugPrintId("response", id);

        // Parse response using either arena or client allocator
        var response: protocol.Response = undefined;
        var need_clone = false;
        
        if (arena_opt) |arena| {
            // Using arena allocator for temporary parsing
            response = try protocol.parseResponseArena(arena, json);
            need_clone = true;
        } else {
            // Using client's allocator directly
            response = try protocol.parseResponse(self.allocator, json);
        }
        
        // First check if this matches any pending request
        var matched = false;
        for (self.pending_requests.items, 0..) |*req, index| {
            std.debug.print("Comparing with pending request at index {}: ", .{index});
            debugPrintId("request", req.id);
            
            if (compareIds(req.id, id)) {
                req.completed = true;
                
                // If using arena, make a permanent copy for the request state
                if (need_clone) {
                    req.response = try protocol.cloneResponse(self.allocator, response);
                } else {
                    req.response = response;
                }
                
                matched = true;
                std.debug.print("✅ MATCHED! Response for request at index {}\n", .{index});
                break;
            } else {
                std.debug.print("❌ NO MATCH for request at index {}\n", .{index});
            }
        }
        
        // If not matched, queue it for later processing
        if (!matched) {
            std.debug.print("⚠️ Queueing unmatched response for ", .{});
            debugPrintId("", id);
            
            // If using arena, make a permanent copy for the queue
            if (need_clone) {
                const permanent_response = try protocol.cloneResponse(self.allocator, response);
                try self.message_queue.append(permanent_response);
            } else {
                try self.message_queue.append(response);
            }
        }
    }
    

    fn handleNotification(self: *Client, json: protocol.Value, arena_opt: ?std.mem.Allocator) !void {
        // Currently not using arena_opt, but keeping the parameter for future use
        // TODO: Consider using arena for temporary allocations if needed in the future
        _ = arena_opt; // Silence unused parameter warning
        
        const method = json.object.get("method") orelse return;
        if (method != .string) return;

        const params = json.object.get("params");

        if (std.mem.eql(u8, method.string, "$/progress")) {
            if (params == null or params.? != .object) return;

            const token = params.?.object.get("token") orelse return;
            const progress = params.?.object.get("progress") orelse return;
            const total = params.?.object.get("total");

            // Find matching request with this progress token
            for (self.pending_requests.items) |*req| {
                if (req.progress_token) |*req_token| {
                    if (protocol.valuesEqual(req_token.*, token)) {
                        // Call progress callback if set
                        if (req.on_progress) |callback| {
                            callback(
                                token,
                                if (progress == .float) progress.float else @as(f64, @floatFromInt(progress.integer)),
                                if (total) |t| if (t == .float) t.float else if (t == .integer) @as(f64, @floatFromInt(t.integer)) else 0.0 else null,
                                req.user_context,
                            );
                        }
                        return;
                    }
                }
            }

            // Global progress callback as fallback
            if (self.callback_context.on_progress) |callback| {
                callback(
                    token,
                    if (progress == .float) progress.float else @as(f64, @floatFromInt(progress.integer)),
                    if (total) |t| if (t == .float) t.float else if (t == .integer) @as(f64, @floatFromInt(t.integer)) else 0.0 else null,
                    self.callback_context.user_context,
                );
            }
        } else if (std.mem.eql(u8, method.string, "logging/log")) {
            if (params == null or params.? != .object) return;

            const level = params.?.object.get("level") orelse return;
            const message = params.?.object.get("message") orelse return;

            if (level != .string or message != .string) return;

            if (self.callback_context.on_log) |callback| {
                callback(level.string, message.string, self.callback_context.user_context);
            }
        } else if (std.mem.eql(u8, method.string, "notifications/listChanged")) {
            if (params == null or params.? != .object) return;

            const type_value = params.?.object.get("type") orelse return;
            if (type_value != .string) return;

            if (std.mem.eql(u8, type_value.string, "tools")) {
                if (self.callback_context.on_tools_changed) |callback| {
                    callback(self.callback_context.user_context);
                }
            } else if (std.mem.eql(u8, type_value.string, "resources")) {
                if (self.callback_context.on_resources_changed) |callback| {
                    callback(self.callback_context.user_context);
                }
            } else if (std.mem.eql(u8, type_value.string, "prompts")) {
                if (self.callback_context.on_prompts_changed) |callback| {
                    callback(self.callback_context.user_context);
                }
            }
        }
    }

    fn handleRequest(self: *Client, json: protocol.Value, arena_opt: ?std.mem.Allocator) !void {
        // Currently not using arena_opt, but keeping the parameter for future use
        // TODO: Consider using arena for temporary allocations if needed in the future
        _ = arena_opt; // Silence unused parameter warning
        
        const method = json.object.get("method") orelse return;
        if (method != .string) return;

        const id = json.object.get("id") orelse return;

        // Handle ping requests
        if (std.mem.eql(u8, method.string, "ping")) {
            try self.sendResponse(id, .{ .null = {} }, null);
            return;
        }

        // Other request types can be added here
    }

    fn nextId(self: *Client) protocol.Value {
        const id = self.next_id;
        self.next_id += 1;
        return .{ .integer = id };
    }

    fn waitForResponseSimple(self: *Client, id: protocol.Value) !protocol.Response {
        std.debug.print("waitForResponseSimple: waiting for id {}\n", .{if (id == .integer) id.integer else @as(u32, 0)});
        return self.waitForResponse(id, null);
    }

    fn sendRequest(self: *Client, method: []const u8, params: ?protocol.Value, id: protocol.Value) !void {
        std.debug.print("Sending request with method: {s}, ", .{method});
        debugPrintId("request", id);
        
        // Display pending requests before adding
        std.debug.print("Current pending requests: {d}\n", .{self.pending_requests.items.len});
        
        // Only add to pending requests if this is a method that expects a response
        // and if we're not using an existing request state (like in callTool)
        var found = false;
        for (self.pending_requests.items) |*req| {
            if (compareIds(req.id, id)) {
                found = true;
                std.debug.print("Request already in pending_requests list\n", .{});
                break;
            }
        }
        
        if (!found) {
            // Create request state with a cloned ID to ensure ownership
            const req_state = RequestState{
                .id = try protocol.cloneValue(self.allocator, id),
                .allocator = self.allocator,
            };
            
            // Add to pending requests
            try self.pending_requests.append(req_state);
            
            std.debug.print("Added to pending requests, new count: {d}\n", .{self.pending_requests.items.len});
        }
        
        const request = protocol.Request{
            .jsonrpc = "2.0",
            .method = method,
            .id = id,
            .params = params,
        };

        const message = try self.serializeMessage(request);
        defer self.allocator.free(message);

        if (self.debug_file) |file| {
            try file.writer().print("Sending request: {s}\n", .{message});
        }

        switch (self.transport) {
            .Stdio => |stdio| {
                try stdio.stdin.writer().writeAll(message);
                try stdio.stdin.writer().writeByte('\n');
            },
            .Http => {
                // Not implemented
            },
        }
    }

    fn sendResponse(self: *Client, id: protocol.Value, result: protocol.Value, error_value: ?protocol.ResponseError) !void {
        const response = protocol.Response{
            .jsonrpc = "2.0",
            .id = id,
            .result = result,
            .@"error" = error_value,
        };

        const message = try self.serializeMessage(response);
        defer self.allocator.free(message);

        if (self.debug_file) |file| {
            try file.writer().print("Sending response: {s}\n", .{message});
        }

        switch (self.transport) {
            .Stdio => |stdio| {
                try stdio.stdin.writer().writeAll(message);
                try stdio.stdin.writer().writeByte('\n');
            },
            .Http => {
                // Not implemented
            },
        }
    }

    fn sendNotification(self: *Client, method: []const u8, params: ?protocol.Value) !void {
        const notification = protocol.Notification{
            .jsonrpc = "2.0",
            .method = method,
            .params = params,
        };

        const message = try self.serializeMessage(notification);
        defer self.allocator.free(message);

        if (self.debug_file) |file| {
            try file.writer().print("Sending notification: {s}\n", .{message});
        }

        switch (self.transport) {
            .Stdio => |stdio| {
                try stdio.stdin.writer().writeAll(message);
                try stdio.stdin.writer().writeByte('\n');
            },
            .Http => {
                // Not implemented
            },
        }
    }

    fn serializeMessage(self: *Client, message: anytype) ![]const u8 {
        return try protocol.serializeMessage(self.allocator, message);
    }
};
