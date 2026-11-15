const std = @import("std");
const generated = @import("rx_options").generated_graph;
const entry = if (generated) @import("generated_rx_expression_constraints") else void;
pub const Form = if (generated) entry.Input else enum { Template, Match, Index, Selection };

const Step = if (generated) std.meta.Child(entry.Output) else enum {
    Done,
    InferInterpolations,
    StringResult,
    MatchResult,
    InferSubject,
    InferArms,
    InferFallback,
    InferTarget,
    InferPosition,
    RegisterIndex,
    ReadKeys,
    InferReceiver,
    RegisterSelection,
};

const capacity = 4;

pub fn steps(comptime form: Form) [capacity]Step {
    if (!generated) return switch (form) {
        .Template => .{ .InferInterpolations, .StringResult, .Done, .Done },
        .Match => .{ .MatchResult, .InferSubject, .InferArms, .InferFallback },
        .Index => .{ .InferTarget, .InferPosition, .RegisterIndex, .Done },
        .Selection => .{ .ReadKeys, .InferReceiver, .RegisterSelection, .Done },
    };

    var buffer: [256]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&buffer);
    var result: [capacity]Step = @splat(.Done);
    const ordered = entry.executeValue(scratch.allocator(), form) catch unreachable;

    @memcpy(result[0..ordered.len], ordered);

    return result;
}
