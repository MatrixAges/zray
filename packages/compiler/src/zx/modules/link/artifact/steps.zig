const std = @import("std");
const generated = @import("parser_options").generated_parser;
const rule = if (generated) @import("generated_artifact_link_steps") else void;

const Step = if (generated) std.meta.Child(rule.Output) else enum {
    PrepareGraph,
    MergeTypes,
    LinkDependencies,
    LinkEntry,
    PublishProgram,
};

pub fn graph() [5]Step {
    if (comptime !generated) return .{ .PrepareGraph, .MergeTypes, .LinkDependencies, .LinkEntry, .PublishProgram };

    var buffer: [256]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&buffer);
    const sequence = rule.executeValue(scratch.allocator(), {}) catch unreachable;

    if (sequence.len != 5) @panic("invalid artifact link schedule length");

    return sequence[0..5].*;
}
