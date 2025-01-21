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
            obj.put("type", .{ .string = "integer" }) catch unreachable;
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
            const schema = generateSchema(opt.child, allocator);
            return schema;
        },
        .Struct => |strct| {
            var obj = std.json.ObjectMap.init(allocator);
            obj.put("type", .{ .string = "object" }) catch unreachable;

            var properties = std.json.ObjectMap.init(allocator);
            var required = std.json.Array.init(allocator);

            inline for (strct.fields) |field| {
                const field_schema = generateSchema(field.type, allocator);
                properties.put(field.name, field_schema) catch unreachable;

                // If the field type is not optional, add it to required
                if (@typeInfo(field.type) != .Optional) {
                    required.append(.{ .string = field.name }) catch unreachable;
                }
            }

            obj.put("properties", .{ .object = properties }) catch unreachable;
            if (required.items.len > 0) {
                obj.put("required", .{ .array = required }) catch unreachable;
            }

            return .{ .object = obj };
        },
        else => @compileError("Type not supported for schema generation: " ++ @typeName(T)),
    }
}

fn wrapFunction(comptime name: []const u8, comptime description: []const u8, comptime func: anytype) ToolInstance {
    const Func = @TypeOf(func);
    const func_info = @typeInfo(Func).Fn;

    // For now we only support single parameter functions that return error unions
    if (func_info.params.len != 1) {
        @compileError("Function must take exactly one parameter");
    }

    const return_type = func_info.return_type.?;
    if (@typeInfo(return_type) != .ErrorUnion) {
        @compileError("Function must return an error union");
    }

    const Param = func_info.params[0].type.?;
    const ReturnPayload = @typeInfo(return_type).ErrorUnion.payload;

    // Create the wrapper function that converts between JSON and native types
    const wrapper = struct {
        fn call(json_arg: protocol.Value) protocol.Value {
            // Convert input from JSON to native type
            const native_arg = convertFromJson(Param, json_arg) catch {
                return .{ .string = "Invalid argument type" };
            };

            // Call the function
            const native_result = func(native_arg) catch {
                return .{ .string = "Function call failed" };
            };

            // Convert result back to JSON
            return convertToJson(ReturnPayload, native_result);
        }

        fn getInputSchema(allocator: std.mem.Allocator) protocol.Value {
            // For simple string parameter, create a simple schema
            if (Param == []const u8) {
                var obj = std.json.ObjectMap.init(allocator);
                obj.put("type", .{ .string = "object" }) catch unreachable;

                var properties = std.json.ObjectMap.init(allocator);
                var message_obj = std.json.ObjectMap.init(allocator);
                message_obj.put("type", .{ .string = "string" }) catch unreachable;
                properties.put("message", .{ .object = message_obj }) catch unreachable;
                obj.put("properties", .{ .object = properties }) catch unreachable;

                var required = std.json.Array.init(allocator);
                required.append(.{ .string = "message" }) catch unreachable;
                obj.put("required", .{ .array = required }) catch unreachable;

                return .{ .object = obj };
            } else {
                // For other types, generate schema based on the parameter type
                return generateSchema(Param, allocator);
            }
        }

        fn convertFromJson(comptime T: type, value: protocol.Value) !T {
            return switch (@typeInfo(T)) {
                .Bool => if (value == .bool) value.bool else error.InvalidType,
                .Int => if (value == .integer) @intCast(value.integer) else error.InvalidType,
                .Float => if (value == .float) @floatCast(value.float) else error.InvalidType,
                .Pointer => |ptr| if (ptr.size == .Slice and ptr.child == u8) {
                    if (value != .object) return error.InvalidType;
                    const msg = value.object.get("message") orelse return error.InvalidType;
                    if (msg != .string) return error.InvalidType;
                    return msg.string;
                } else error.InvalidType,
                .Optional => |opt| if (value == .null) null else try convertFromJson(opt.child, value),
                .Array => |arr| if (value == .array) blk: {
                    if (value.array.items.len != arr.len) return error.InvalidLength;
                    var result: [arr.len]arr.child = undefined;
                    for (value.array.items, 0..) |item, i| {
                        result[i] = try convertFromJson(arr.child, item);
                    }
                    break :blk result;
                } else error.InvalidType,
                .Struct => |strct| if (value == .object) blk: {
                    var result: T = undefined;
                    inline for (strct.fields) |field| {
                        if (value.object.get(field.name)) |field_value| {
                            @field(result, field.name) = try convertFromJson(field.type, field_value);
                        } else if (!@typeInfo(field.type).Optional) {
                            return error.MissingField;
                        }
                    }
                    break :blk result;
                } else error.InvalidType,
                else => @compileError("Type not supported for JSON conversion: " ++ @typeName(T)),
            };
        }

        fn convertToJson(comptime T: type, value: T) protocol.Value {
            return switch (@typeInfo(T)) {
                .Bool => .{ .bool = value },
                .Int => .{ .integer = @intCast(value) },
                .Float => .{ .float = @floatCast(value) },
                .Pointer => |ptr| if (ptr.size == .Slice and ptr.child == u8) {
                    return .{ .string = value };
                } else return .{ .string = "Invalid type" },
                .Optional => if (value) |v| convertToJson(@TypeOf(v), v) else .{ .null = {} },
                .Array => .{ .string = "Array conversion not supported yet" },
                .Struct => .{ .string = "Struct conversion not supported yet" },
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
        .Array => |arr| []validateJsonType(arr.child),
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
