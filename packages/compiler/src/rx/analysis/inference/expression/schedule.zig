const std = @import("std");
const generated = @import("rx_options").generated_graph;
const entry = if (generated) @import("generated_rx_expression_constraints") else void;
pub const Form = if (generated) entry.Input else enum { Template, Match, Index, Selection, Object, Sequence, BoundValue, UnboundValue };

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
    ReserveParts,
    PlanFieldHints,
    InferFields,
    ObjectResult,
    SequenceResult,
    ExpectResult,
    InferElements,
    RegisterObject,
    RegisterSequence,
    BoundValue,
    TypeHint,
    InferValue,
    RefineValue,
    RequireValue,
};

const capacity = 6;

pub fn steps(comptime form: Form) [capacity]Step {
    if (!generated) return switch (form) {
        .Template => .{ .InferInterpolations, .StringResult, .Done, .Done, .Done, .Done },
        .Match => .{ .MatchResult, .InferSubject, .InferArms, .InferFallback, .Done, .Done },
        .Index => .{ .InferTarget, .InferPosition, .RegisterIndex, .Done, .Done, .Done },
        .Selection => .{ .ReadKeys, .InferReceiver, .RegisterSelection, .Done, .Done, .Done },
        .Object => .{ .ReserveParts, .PlanFieldHints, .InferFields, .ObjectResult, .ExpectResult, .RegisterObject },
        .Sequence => .{ .SequenceResult, .ExpectResult, .InferElements, .RegisterSequence, .Done, .Done },
        .BoundValue => .{ .BoundValue, .RefineValue, .RequireValue, .ExpectResult, .Done, .Done },
        .UnboundValue => .{ .TypeHint, .InferValue, .RefineValue, .ExpectResult, .Done, .Done },
    };

    var buffer: [256]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&buffer);
    var result: [capacity]Step = @splat(.Done);
    const ordered = entry.executeValue(scratch.allocator(), form) catch unreachable;

    @memcpy(result[0..ordered.len], ordered);

    return result;
}
