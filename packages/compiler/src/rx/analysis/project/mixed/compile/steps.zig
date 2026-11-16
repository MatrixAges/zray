const std = @import("std");
const generated = @import("rx_options").generated_graph;
const rule = if (generated) @import("generated_rx_mixed_compile") else void;
const Form = if (generated) rule.Input else enum { Window, Output };

const Step = if (generated) std.meta.Child(rule.Output) else enum {
    PrepareWindow,
    RestorePrefix,
    NextBody,
    LinkBody,
    RecordBoundary,
    ResolveEntry,
    BuildEntryProgram,
    PublishContract,
    PublishExports,
    RetainHistory,
};

const count = 5;

pub fn steps(comptime form: Form) [count]Step {
    var buffer: [256]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&buffer);
    const sequence = if (generated) rule.executeValue(scratch.allocator(), form) catch unreachable else seed(form);

    return sequence[0..count].*;
}

fn seed(comptime form: Form) []const Step {
    return switch (form) {
        .Window => &.{ .PrepareWindow, .RestorePrefix, .NextBody, .LinkBody, .RecordBoundary },
        .Output => &.{ .ResolveEntry, .BuildEntryProgram, .PublishContract, .PublishExports, .RetainHistory },
    };
}
