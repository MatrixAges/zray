const std = @import("std");
const zx = @import("zx");
const Terms = @import("../terms.zig");
const ir = @import("../ir.zig");
const Conditions = @import("../../../verification/conditions.zig");
const inputs = @import("generated_hardware_bind_inputs");
const definition = @import("generated_hardware_publish_definition");

pub fn bindInputs(terms: *Terms, symbols: []const Conditions.Input) Terms.Error!void {
    const table = terms.variables.view();
    const names = zx.memory.borrowTextColumn("symbol", symbols);

    const input: std.meta.Child(inputs.Input) = .{
        .current = &table.read(), .target = &table.target(),
        .names = @ptrCast(&names), .count = symbols.len,
    };

    terms.variables.count = zx.columns.invoke(inputs.executeValue, terms.scratch, &input) catch |err| return Terms.fromSourceError(err);
}

pub fn publish(terms: *Terms, name: []const u8, width: u16, id: ir.Id, sort: ir.Sort) Terms.Error!void {
    const table = terms.variables.view();

    const input: std.meta.Child(definition.Input) = .{
        .current = &table.read(), .target = &table.target(),
        .key = name, .value = @backingInt(id), .width = width, .sort = &.{ .width = sort.width, .boolean = sort.boolean },
    };

    const added = zx.columns.invoke(definition.executeValue, terms.scratch, &input) catch |err| return Terms.fromSourceError(err);

    terms.variables.count += @intFromBool(added orelse return error.InvalidHardwareTerm);
}
