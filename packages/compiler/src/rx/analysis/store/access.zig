const std = @import("std");
const zx = @import("zx");
const Indexed = @import("frontend").ExpressionInput.Indexed;
const Binding = @import("../store.zig").Binding;
const Scope = @import("references.zig").Scope;
const Setter = struct { list: bool, position: ?usize, offset: usize };

pub fn reads(allocator: std.mem.Allocator, backing: std.mem.Allocator, parsed: Indexed, scope: Scope) std.mem.Allocator.Error![]Binding {
    var arena = std.heap.ArenaAllocator.init(backing);
    var buffer: [std.heap.page_size_min / 8]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    defer arena.deinit();

    const positions = try select(@import("generated_rx_store_reads").executeValue, scratch.allocator(), parsed, scope.names);
    const result = try allocator.alloc(Binding, positions.len);

    for (result, positions) |*binding, index| binding.* = scope.at(@intCast(index));

    return result;
}

pub fn setter(backing: std.mem.Allocator, parsed: Indexed, names: []const []const u8) std.mem.Allocator.Error!Setter {
    var arena = std.heap.ArenaAllocator.init(backing);
    var buffer: [std.heap.page_size_min / 8]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    defer arena.deinit();

    const selected = try select(@import("generated_rx_store_setter").executeValue, scratch.allocator(), parsed, names);

    return .{ .list = selected.list, .position = if (selected.position) |index| @intCast(index) else null, .offset = @intCast(selected.offset) };
}

fn select(comptime rule: anytype, allocator: std.mem.Allocator, parsed: Indexed, names: []const []const u8) std.mem.Allocator.Error!@typeInfo(@typeInfo(@TypeOf(rule)).@"fn".return_type.?).error_union.payload {
    return zx.columns.invoke(rule, allocator, &.{ .source = parsed.source, .tree = parsed.output.expressions, .root = parsed.output.result, .names = names }) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };
}
