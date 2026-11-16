const std = @import("std");
const zx = @import("zx");
const memory = @import("zxc_standard").memory;
const Object = @import("genz").zx.state.Object;
const rule = @import("generated_state_objects");

pub fn create(allocator: std.mem.Allocator, modules: []const []const u8, writable: []const bool, independent: bool) std.mem.Allocator.Error![]const Object {
    const objects = try allocator.alloc(Object, modules.len);

    errdefer allocator.free(objects);

    const names = memory.borrowWriteColumn([]const u8, "module_name", objects);
    const access = memory.borrowWriteColumn(u8, "writable", objects);
    const ownership = memory.borrowWriteColumn(u8, "independent", objects);

    const input: std.meta.Child(rule.Input) = .{
        .modules = modules,
        .writable = writable,
        .independent = independent,
        .names = @ptrCast(&names),
        .access = @ptrCast(&access),
        .ownership = @ptrCast(&ownership),
    };

    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    return objects;
}
