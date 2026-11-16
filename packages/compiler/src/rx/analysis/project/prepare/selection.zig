const std = @import("std");
const rx = @import("rx");
const target = @import("../../call/target.zig");
const Flow = @import("../flow.zig");
const rule = @import("generated_rx_prepared_selection");

pub fn bind(allocator: std.mem.Allocator, indexed: *const rx.IndexedFlow, node: *const rx.ast.Node, subject: *const rx.ast.Attribute, conditional: bool, has_else: bool) std.mem.Allocator.Error![]Flow.Case {
    const children = node.children;
    const count = if (conditional) @as(usize, 1) + @intFromBool(has_else) else children.len;
    const cases = try allocator.alloc(Flow.Case, count);
    const bytes = std.mem.sliceAsBytes(cases);
    const words = std.mem.bytesAsSlice(u32, bytes);
    const word_size = @sizeOf(u32);
    const body = @offsetOf(Flow.Case, "body");
    const first = body + @offsetOf(Flow.Unit, "first");
    const length = body + @offsetOf(Flow.Unit, "count");
    const tag = @offsetOf(Flow.Case, "label") + @offsetOf(Flow.Case.Label, "kind");

    comptime {
        if (@alignOf(Flow.Case) < @alignOf(u32) or @sizeOf(Flow.Case) % word_size != 0 or
            first % word_size != 0 or length % word_size != 0 or

            @sizeOf(Flow.Case.Label.Kind) != @sizeOf(u8))
        {
            @compileError("Incompatible layout for borrowing branch rows");
        }
    }

    const input: std.meta.Child(rule.Input) = .{
        .units = &.{ .firsts = indexed.unit_firsts, .counts = indexed.unit_counts },
        .rows = &.{
            .tags = @ptrCast(&bytes),
            .words = @ptrCast(&words),
            .tag_offset = tag,
            .first_offset = first / word_size,
            .count_offset = length / word_size,
            .byte_stride = @sizeOf(Flow.Case),
            .word_stride = @sizeOf(Flow.Case) / word_size,
        },
        .labels = &.{
            .ordinary = @backingInt(Flow.Case.Label.Kind.Case),
            .affirmative = @backingInt(Flow.Case.Label.Kind.Affirmative),
            .fallback = @backingInt(Flow.Case.Label.Kind.Default),
        },
        .facts = @ptrCast(indexed.facts),
        .first_child = if (children.len != 0) indexed.row(&children[0]) else 0,
        .child_count = children.len,
        .subject = indexed.row(node),
        .conditional = conditional,
        .has_else = has_else,
    };

    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    rule.executeValue(scratch.allocator(), &input) catch unreachable;

    for (cases, 0..) |*case, row| {
        case.label.source = switch (case.label.kind) {
            .Case => target.borrowAttribute(children[row], "value").?,
            .Affirmative => subject,
            .Default => null,
        };

        case.truth = null;
    }

    return cases;
}
