const std = @import("std");
const zx = @import("zx");
const Terms = @import("../terms.zig");
const ir = @import("../ir.zig");
const Conditions = @import("../../../verification/conditions.zig");
const inputs = @import("generated_hardware_bind_inputs");
const definition = @import("generated_hardware_publish_definition");

pub fn bindInputs(terms: *Terms, symbols: []const Conditions.Input) Terms.Error!void {
    if (symbols.len == 0) return;

    const table = terms.variables.view();
    const names = zx.memory.borrowTextColumn("symbol", symbols);
    var arena = std.heap.ArenaAllocator.init(terms.scratch);

    defer arena.deinit();

    const input: std.meta.Child(inputs.Input) = .{
        .capacity = table.keys.len,
        .names = @ptrCast(&names),
        .count = symbols.len,
    };

    const bound = zx.columns.invoke(inputs.executeValue, arena.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        error.IndexOutOfBounds, error.IntegerOverflow => return error.InvalidHardwareTerm,
        else => unreachable,
    };

    @memcpy(table.keys, bound.keys);
    @memcpy(table.values, bound.values);

    terms.variables.count = bound.count;
}

pub fn publish(terms: *Terms, name: []const u8, width: u16, id: ir.Id, sort: ir.Sort) Terms.Error!void {
    const table = terms.variables.view();
    var arena = std.heap.ArenaAllocator.init(terms.scratch);

    defer arena.deinit();

    var buffer: [128]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    const input: std.meta.Child(definition.Input) = .{
        .keys = table.keys,
        .key = name,
        .width = width,
        .sort = &.{ .width = sort.width, .boolean = sort.boolean },
    };

    const placement = (zx.columns.invoke(definition.executeValue, scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        error.IndexOutOfBounds, error.IntegerOverflow, error.Overflow => return error.InvalidHardwareTerm,
        else => unreachable,
    }) orelse return error.InvalidHardwareTerm;

    const slot: usize = @intCast(placement.slot);

    if (placement.fresh) {
        terms.variables.fillVacant(slot, name, id);
    } else {
        table.values[slot] = @backingInt(id);
    }
}
