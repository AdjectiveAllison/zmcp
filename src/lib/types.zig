const std = @import("std");
const protocol = @import("protocol.zig");

pub fn convertJsonToNative(comptime T: type, json: protocol.Value) !T {
    return switch (@typeInfo(T)) {
        .Bool => json.bool,
        .Int => @intCast(json.integer),
        .Float => @floatCast(json.float),
        .Pointer => |ptr| if (ptr.size == .Slice and ptr.child == u8) {
            return json.string;
        } else {
            @compileError("Only string slices are supported");
        },
        .Optional => |opt| if (json == .null) null else try convertJsonToNative(opt.child, json),
        .Array => |arr| blk: {
            if (json != .array) return error.InvalidType;
            if (json.array.items.len != arr.len) return error.InvalidLength;
            var result: [arr.len]arr.child = undefined;
            for (json.array.items, 0..) |item, i| {
                result[i] = try convertJsonToNative(arr.child, item);
            }
            break :blk result;
        },
        else => @compileError("Unsupported type: " ++ @typeName(T)),
    };
}

pub fn convertNativeToJson(allocator: std.mem.Allocator, value: anytype) !protocol.Value {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .Bool => .{ .bool = value },
        .Int => .{ .integer = @intCast(value) },
        .Float => .{ .float = @floatCast(value) },
        .Pointer => |ptr| if (ptr.size == .Slice and ptr.child == u8) {
            return .{ .string = try allocator.dupe(u8, value) };
        } else {
            @compileError("Only string slices are supported");
        },
        .Optional => if (value) |v| try convertNativeToJson(allocator, v) else .{ .null = {} },
        .Array => blk: {
            var array = std.json.Array.init(allocator);
            for (value) |item| {
                try array.append(try convertNativeToJson(allocator, item));
            }
            break :blk .{ .array = array };
        },
        else => @compileError("Unsupported type: " ++ @typeName(T)),
    };
}
