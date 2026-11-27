const std = @import("std");
const zx = @import("zx");
const Object = @import("genz").zx.state.Object;
const rule = @import("generated_state_objects");

pub fn create(allocator: std.mem.Allocator, modules: []const []const u8, writable: []const bool, independent: bool) std.mem.Allocator.Error![]const Object {
    var buffer: [1024]u8 align(@alignOf(u64)) = undefined;
    var backing = std.heap.BufferFirstAllocator.init(&buffer, allocator);
    var scratch = std.heap.ArenaAllocator.init(backing.allocator());

    defer scratch.deinit();

    const input: std.meta.Child(rule.Input) = .{
        .modules = modules,
        .writable = writable,
        .independent = independent,
    };

    const result = zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    const objects = try allocator.alloc(Object, result.len);

    for (result, objects) |item, *slot| {
        slot.* = .{
            .module_name = item.module_name,
            .writable = item.writable,
            .independent = item.independent,
        };
    }

    return objects;
}
