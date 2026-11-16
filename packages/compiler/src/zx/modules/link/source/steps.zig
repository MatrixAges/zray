const std = @import("std");
const generated = @import("parser_options").generated_parser;
const rule = if (generated) @import("generated_source_link_steps") else void;
const Phase = if (generated) rule.Input else enum { Body, Surface };

const Step = if (generated) std.meta.Child(rule.Output) else enum {
    CheckViews,
    SelectSuffix,
    VerifyIr,
    MergeTypes,
    AppendFunctions,
    FinishBody,
    PublishEntry,
    PublishDeclarations,
    PublishInitializers,
    PublishMembers,
    ResolvePorts,
};

pub fn run(comptime phase: Phase) if (phase == .Body) [6]Step else [5]Step {
    var buffer: [256]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&buffer);
    const sequence = if (generated) rule.executeValue(scratch.allocator(), phase) catch unreachable else seed(phase);
    const count = if (phase == .Body) 6 else 5;

    if (sequence.len != count) @panic("invalid source link schedule length");

    return sequence[0..count].*;
}

fn seed(comptime phase: Phase) []const Step {
    return switch (phase) {
        .Body => &.{ .CheckViews, .SelectSuffix, .VerifyIr, .MergeTypes, .AppendFunctions, .FinishBody },
        .Surface => &.{ .PublishEntry, .PublishDeclarations, .PublishInitializers, .PublishMembers, .ResolvePorts },
    };
}
