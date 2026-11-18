const std = @import("std");
const zx = @import("zx");
const ir = @import("../ir.zig");
const binary = @import("../binary.zig");
const Terms = @import("../terms.zig");
const limits = @import("generated_hardware_limits").@"zx.constants";
const read = @import("generated_hardware_term_read");
const boundary = @import("generated_hardware_term_boundary");
const derive = @import("generated_hardware_term_sort");
const Head = @typeInfo(@typeInfo(@TypeOf(read.executeValue)).@"fn".return_type.?).error_union.payload;
const Self = @This();

tables: *Terms,
source: []const u8,

offset: usize = 0,
pub fn parse(tables: *Terms, source: []const u8) Terms.Error!ir.Id {
    if (source.len > limits.maximum_source_bytes) return error.InvalidHardwareTerm;

    var reader: Self = .{ .tables = tables, .source = source };
    const id = try reader.term(0);

    try reader.finish(false);

    return id;
}

fn term(self: *Self, depth: usize) Terms.Error!ir.Id {
    if (depth >= limits.maximum_depth) return error.InvalidHardwareTerm;

    const cursor: std.meta.Child(read.Input) = .{ .source = self.source, .offset = self.offset };
    const head = zx.columns.invoke(read.executeValue, self.tables.scratch, &cursor) catch |err| return Terms.fromSourceError(err);

    self.offset = @intCast(head.next);

    const node: ir.Node = switch (head.form) {
        .Invalid => return error.InvalidHardwareTerm,
        .Open, .Indexed => unreachable,
        .Name, .True, .False => node: {
            const key = self.source[@intCast(head.start)..self.offset];
            const binding = try self.tables.variables.find(self.tables.scratch, key);

            if (binding.value) |id| return @fromBackingInt(id);
            if (head.form == .Name) return error.InvalidHardwareTerm;

            break :node .{ .sort = .{ .width = 1, .boolean = true }, .value = .{ .constant = @intFromBool(head.form == .True) } };
        },
        .Constant => .{ .sort = .{ .width = @intCast(head.bits) }, .value = .{ .constant = head.value } },
        else => try self.application(head, depth),
    };

    return self.tables.intern(self.source[@intCast(head.start)..self.offset], node);
}

fn application(self: *Self, head: Head, depth: usize) Terms.Error!ir.Node {
    var operands: [3]ir.Id = undefined;
    var sorts: [3]ir.Sort = @splat(.{ .width = 0 });

    for (operands[0..head.arity], sorts[0..head.arity]) |*operand, *sort| {
        operand.* = try self.term(depth + 1);
        sort.* = self.tables.nodes.items[@backingInt(operand.*)].sort;
    }

    try self.finish(true);

    const operator = if (head.form == .Binary) binary.names.get(self.source[@intCast(head.operator_start)..@intCast(head.next)]) orelse return error.InvalidHardwareTerm else null;

    const input: std.meta.Child(derive.Input) = .{
        .form = head.form,
        .extra = @intCast(head.bits),
        .family = if (operator) |op| binary.traits(op).family else .Logical,
        .left = &.{ .width = sorts[0].width, .boolean = sorts[0].boolean },
        .right = &.{ .width = sorts[1].width, .boolean = sorts[1].boolean },
        .third = &.{ .width = sorts[2].width, .boolean = sorts[2].boolean },
    };

    const sort = try zx.columns.invoke(derive.executeValue, self.tables.scratch, &input);

    if (sort.width == 0) return error.InvalidHardwareTerm;

    return .{
        .sort = .{ .width = sort.width, .boolean = sort.boolean },
        .value = switch (head.form) {
            .Binary => .{ .binary = .{ .operator = operator.?, .left = operands[0], .right = operands[1] } },
            .Invert => .{ .invert = operands[0] },
            .Negate => .{ .negate = operands[0] },
            .Select => .{ .select = .{ .condition = operands[0], .yes = operands[1], .no = operands[2] } },
            .ZeroExtend, .SignExtend => .{ .extend = .{ .operand = operands[0], .extra = @intCast(head.bits), .signed = head.form == .SignExtend } },
            else => unreachable,
        },
    };
}

fn finish(self: *Self, closing: bool) Terms.Error!void {
    const input: std.meta.Child(boundary.Input) = .{ .source = self.source, .offset = self.offset, .closing = closing };
    const next = zx.columns.invoke(boundary.executeValue, self.tables.scratch, &input) catch |err| return Terms.fromSourceError(err);

    self.offset = @intCast(next orelse return error.InvalidHardwareTerm);
}
