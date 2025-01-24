const std = @import("std");
const protocol = @import("protocol.zig");
const types = @import("types.zig");

pub const ToolInstance = struct {
    name: []const u8,
    description: []const u8,
    call: *const fn (protocol.Value) protocol.Value,
    input_schema: *const fn (std.mem.Allocator) protocol.Value,

    pub fn toJson(self: ToolInstance, allocator: std.mem.Allocator) protocol.Value {
        var obj = std.json.ObjectMap.init(allocator);
        obj.put("name", .{ .string = self.name }) catch unreachable;
        obj.put("description", .{ .string = self.description }) catch unreachable;
        obj.put("inputSchema", self.input_schema(allocator)) catch unreachable;
        return .{ .object = obj };
    }
};

fn generateSchema(comptime T: type, allocator: std.mem.Allocator) protocol.Value {
    switch (@typeInfo(T)) {
        .Bool => {
            var obj = std.json.ObjectMap.init(allocator);
            obj.put("type", .{ .string = "boolean" }) catch unreachable;
            return .{ .object = obj };
        },
        .Int => {
            var obj = std.json.ObjectMap.init(allocator);
            obj.put("type", .{ .string = "number" }) catch unreachable;
            return .{ .object = obj };
        },
        .Float => {
            var obj = std.json.ObjectMap.init(allocator);
            obj.put("type", .{ .string = "number" }) catch unreachable;
            return .{ .object = obj };
        },
        .Pointer => |ptr| if (ptr.size == .Slice and ptr.child == u8) {
            var obj = std.json.ObjectMap.init(allocator);
            obj.put("type", .{ .string = "string" }) catch unreachable;
            return .{ .object = obj };
        } else @compileError("Only string slices are supported"),
        .Optional => |opt| {
            // For optional fields, we need to allow null in addition to the base type
            var obj = std.json.ObjectMap.init(allocator);
            var type_array = std.json.Array.init(allocator);
            type_array.append(.{ .string = "null" }) catch unreachable;

            // Get the schema for the base type
            const base_schema = generateSchema(opt.child, allocator);
            if (base_schema.object.get("type")) |type_val| {
                type_array.append(type_val) catch unreachable;
            }

            obj.put("type", .{ .array = type_array }) catch unreachable;
            return .{ .object = obj };
        },
        .Struct => |strct| {
            var obj = std.json.ObjectMap.init(allocator);
            obj.put("type", .{ .string = "object" }) catch unreachable;

            var properties = std.json.ObjectMap.init(allocator);
            var required = std.json.Array.init(allocator);

            inline for (strct.fields) |field| {
                // Skip allocator field in schema
                if (comptime std.mem.eql(u8, field.name, "allocator")) continue;

                const field_schema = generateSchema(field.type, allocator);
                properties.put(field.name, field_schema) catch unreachable;

                // If the field type is not optional and has no default value, add it to required
                if (@typeInfo(field.type) != .Optional and field.default_value == null) {
                    required.append(.{ .string = field.name }) catch unreachable;
                }
            }

            obj.put("properties", .{ .object = properties }) catch unreachable;
            if (required.items.len > 0) {
                obj.put("required", .{ .array = required }) catch unreachable;
            }

            return .{ .object = obj };
        },
        .Array => |info| {
            var obj = std.json.ObjectMap.init(allocator);
            obj.put("type", .{ .string = "array" }) catch unreachable;
            obj.put("items", generateSchema(info.child, allocator)) catch unreachable;
            return .{ .object = obj };
        },
        else => @compileError("Type not supported for schema generation: " ++ @typeName(T)),
    }
}

fn wrapFunction(comptime name: []const u8, comptime description: []const u8, comptime func: anytype) ToolInstance {
    const Func = @TypeOf(func);
    const func_info = @typeInfo(Func).Fn;

    // Validate function has exactly one parameter
    if (func_info.params.len != 1) {
        @compileError("Tool function must take exactly one parameter");
    }

    // Get parameter type and validate it's a struct
    const ParamType = func_info.params[0].type.?;
    if (@typeInfo(ParamType) != .Struct) {
        @compileError("Tool function parameter must be a struct");
    }

    const return_type = func_info.return_type.?;
    if (@typeInfo(return_type) != .ErrorUnion) {
        @compileError("Function must return an error union");
    }

    const ReturnPayload = @typeInfo(return_type).ErrorUnion.payload;

    // Create the wrapper function that converts between JSON and native types
    const wrapper = struct {
        fn call(json_arg: protocol.Value) protocol.Value {
            // Use page_allocator for strings that need to persist beyond this call
            const persistent_allocator = std.heap.page_allocator;

            // Use arena for temporary allocations during the call
            var arena = std.heap.ArenaAllocator.init(persistent_allocator);
            const temp_allocator = arena.allocator();

            if (json_arg != .object) {
                arena.deinit();
                return .{ .string = "Arguments must be an object" };
            }

            // Convert JSON directly to parameter struct
            var params = convertFromJson(ParamType, json_arg) catch |err| {
                var msg = std.ArrayList(u8).init(temp_allocator);
                std.fmt.format(msg.writer(), "Invalid parameters: {s}", .{@errorName(err)}) catch unreachable;
                const str = persistent_allocator.dupe(u8, msg.items) catch unreachable;
                const result = .{ .string = str };
                arena.deinit();
                return result;
            };

            // Add allocator to params if struct has allocator field
            if (@hasField(ParamType, "allocator")) {
                params.allocator = temp_allocator;
            }

            // Call the function with the struct parameter
            const native_result = func(params) catch |err| {
                var msg = std.ArrayList(u8).init(temp_allocator);
                std.fmt.format(msg.writer(), "Function call failed: {s}", .{@errorName(err)}) catch unreachable;
                const str = persistent_allocator.dupe(u8, msg.items) catch unreachable;
                const result = .{ .string = str };
                arena.deinit();
                return result;
            };

            // Convert result back to JSON using the persistent allocator
            const result = convertToJson(ReturnPayload, native_result, persistent_allocator);
            arena.deinit();
            return result;
        }

        fn getInputSchema(allocator: std.mem.Allocator) protocol.Value {
            return generateSchema(ParamType, allocator);
        }

        fn convertFromJson(comptime T: type, value: protocol.Value) !T {
            return switch (@typeInfo(T)) {
                .Bool => if (value == .bool) value.bool else error.InvalidType,
                .Int => |int_info| {
                    // Handle both integer and float JSON values
                    if (value == .integer) {
                        const val = value.integer;
                        if (int_info.signedness == .signed) {
                            return @intCast(val);
                        } else {
                            if (val < 0) return error.InvalidValue;
                            return @intCast(val);
                        }
                    } else if (value == .float) {
                        const val = @floor(value.float);
                        if (val != value.float) return error.InvalidValue; // Ensure it's a whole number
                        if (int_info.signedness == .signed) {
                            return @intCast(@as(i64, @intFromFloat(val)));
                        } else {
                            if (val < 0) return error.InvalidValue;
                            return @intCast(@as(u64, @intFromFloat(val)));
                        }
                    } else return error.InvalidType;
                },
                .Float => if (value == .float) @floatCast(value.float) else if (value == .integer) @floatCast(@as(f64, @floatFromInt(value.integer))) else error.InvalidType,
                .Pointer => |ptr| if (ptr.size == .Slice and ptr.child == u8) {
                    if (value != .string) return error.InvalidType;
                    return value.string;
                } else error.InvalidType,
                .Optional => |opt| if (value == .null) null else try convertFromJson(opt.child, value),
                .Array => |info| if (value == .array) blk: {
                    if (value.array.items.len != info.len) return error.InvalidLength;
                    var result: [info.len]info.child = undefined;
                    for (value.array.items, 0..) |item, i| {
                        result[i] = try convertFromJson(info.child, item);
                    }
                    break :blk result;
                } else error.InvalidType,
                .Struct => |strct| if (value == .object) blk: {
                    var result: T = undefined;
                    inline for (strct.fields) |field| {
                        // Skip allocator field in conversion
                        if (comptime std.mem.eql(u8, field.name, "allocator")) continue;

                        if (value.object.get(field.name)) |field_value| {
                            @field(result, field.name) = try convertFromJson(field.type, field_value);
                        } else {
                            // Check if the field type is optional
                            const field_type_info = @typeInfo(field.type);
                            if (field_type_info == .Optional) {
                                @field(result, field.name) = null;
                            } else if (field.default_value) |default_ptr| {
                                // Use default value if available
                                const default = @as(*const field.type, @alignCast(@ptrCast(default_ptr))).*;
                                @field(result, field.name) = default;
                            } else {
                                return error.MissingField;
                            }
                        }
                    }
                    break :blk result;
                } else error.InvalidType,
                else => @compileError("Type not supported for JSON conversion: " ++ @typeName(T)),
            };
        }

        fn convertToJson(comptime T: type, value: T, allocator: std.mem.Allocator) protocol.Value {
            return switch (@typeInfo(T)) {
                .Bool => .{ .bool = value },
                .Int => .{ .integer = @intCast(value) },
                .Float => .{ .float = @floatCast(value) },
                .Pointer => |ptr| if (ptr.size == .Slice and ptr.child == u8) {
                    // Always duplicate strings to ensure they're owned by the right allocator
                    const str = allocator.dupe(u8, value) catch unreachable;
                    return .{ .string = str };
                } else return .{ .string = "Invalid type" },
                .Optional => if (value) |v| convertToJson(@TypeOf(v), v, allocator) else .{ .null = {} },
                .Array => blk: {
                    var array = std.json.Array.init(allocator);
                    for (value) |item| {
                        array.append(convertToJson(@TypeOf(item), item, allocator)) catch unreachable;
                    }
                    break :blk .{ .array = array };
                },
                .Struct => blk: {
                    var obj = std.json.ObjectMap.init(allocator);
                    inline for (std.meta.fields(T)) |field| {
                        // Skip allocator field in conversion
                        if (comptime std.mem.eql(u8, field.name, "allocator")) continue;

                        const field_value = @field(value, field.name);
                        obj.put(field.name, convertToJson(@TypeOf(field_value), field_value, allocator)) catch unreachable;
                    }
                    break :blk .{ .object = obj };
                },
                else => .{ .string = "Type not supported for JSON conversion" },
            };
        }
    };

    return .{
        .name = name,
        .description = description,
        .call = wrapper.call,
        .input_schema = wrapper.getInputSchema,
    };
}

pub fn Tool(comptime name: []const u8, comptime description: []const u8, comptime func: anytype) ToolInstance {
    return wrapFunction(name, description, func);
}

pub fn IsMcpTool(comptime T: type) bool {
    return @hasDecl(T, "name") and
        @hasDecl(T, "description") and
        @hasDecl(T, "function") and
        @hasDecl(T, "__mcp_tool_marker");
}

pub fn validateJsonType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .Bool => bool,
        .Int => i64, // Convert to JSON-compatible integer
        .Float => f64, // Convert to JSON-compatible float
        .Pointer => |ptr| if (ptr.size == .Slice and ptr.child == u8)
            []const u8
        else
            @compileError("Invalid type"),
        .Optional => |opt| ?validateJsonType(opt.child),
        .Array => |info| []validateJsonType(info.child),
        .Struct => |strct| struct {
            pub fn toJson(self: @This(), allocator: std.mem.Allocator) !protocol.Value {
                var obj = std.json.ObjectMap.init(allocator);
                inline for (strct.fields) |field| {
                    const field_value = @field(self, field.name);
                    try obj.put(field.name, switch (@TypeOf(field_value)) {
                        bool => .{ .bool = field_value },
                        i64 => .{ .integer = field_value },
                        f64 => .{ .float = field_value },
                        []const u8 => .{ .string = field_value },
                        else => try field_value.toJson(allocator),
                    });
                }
                return .{ .object = obj };
            }
        },
        else => @compileError("Type not supported for JSON conversion: " ++ @typeName(T)),
    };
}
