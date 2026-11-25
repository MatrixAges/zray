const std = @import("std");
const zx = @import("zx");
const syntax = zx.syntax.borrow;
const Graph = @import("types.zig");
const Expression = @import("expression.zig");
const Construction = @import("construction.zig");

pub fn infer(self: *Expression, fields: anytype, expected: ?Graph.Id, span: zx.Span) zx.Error!Graph.Id {
    const first = self.graph.pending.construction_parts.len;
    const indexed = @import("rx_options").generated_graph and @typeInfo(@TypeOf(fields)) == .@"struct";
    var buffer: [32]u32 = undefined;

    try self.graph.pending.construction_parts.resize(self.graph.pending.allocator, first + fields.len);

    const hints: []const u32 = if (indexed and expected != null and fields.len > 1)
        try markHints(self.graph.scratch, fields, &buffer)
    else
        &.{};

    defer if (hints.len > buffer.len) self.graph.scratch.free(hints);

    try inferFields(self, fields, expected, first, hints, indexed);

    const result = try self.graph.add(.{ .object = .{} }, span);

    if (expected) |target| try self.graph.expect(result, target, span);

    try self.graph.pending.constructions.append(self.graph.pending.allocator, .{
        .result = result,
        .first = first,
        .count = fields.len,
        .span = span,
    });

    return result;
}

fn inferFields(self: *Expression, fields: anytype, expected: ?Graph.Id, first: usize, hints: []const u32, comptime indexed: bool) zx.Error!void {
    for (0..fields.len) |index| {
        const field = syntax.item(fields, index);
        var hint: ?Graph.Id = null;

        if (!field.spread and expected != null) {
            const final_field = if (indexed) hints.len == 0 or hints[index] != 0 else seedHint(fields, index, field.name.text);

            if (final_field) hint = try self.graph.field(expected.?, field.name.text, self.sourceSpan(field.name.span));
        }

        const part: Construction.Part = .{
            .name = if (field.spread) null else try self.graph.pending.allocator.dupe(u8, field.name.text),
            .value = try self.infer(field.value, hint),
            .span = self.sourceSpan(field.value.span),
        };

        self.graph.pending.construction_parts.set(first + index, part);

        if (field.spread and self.graph.shape(part.value) == .unknown) {
            try self.graph.unify(part.value, try self.graph.add(.{ .object = .{} }, part.span), part.span);
        }
    }
}

fn markHints(allocator: std.mem.Allocator, fields: anytype, buffer: []u32) std.mem.Allocator.Error![]u32 {
    var hints = if (fields.len <= buffer.len) buffer[0..fields.len] else try allocator.alloc(u32, fields.len);
    const context = fields.context;

    @memset(hints, 0);

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    _ = @import("generated_object_construction_hints").executeValue(empty.allocator(), &.{
        .source = context.source,
        .fields = context.storage.expressions.fields,
        .order = context.order.edges[fields.first..][0..fields.len],
        .target = @ptrCast(&hints),
    }) catch unreachable;

    return hints;
}

fn seedHint(fields: anytype, index: usize, name: []const u8) bool {
    for (index + 1..fields.len) |later_index| {
        const later = syntax.item(fields, later_index);

        if (later.spread or std.mem.eql(u8, later.name.text, name)) return false;
    }

    return true;
}
