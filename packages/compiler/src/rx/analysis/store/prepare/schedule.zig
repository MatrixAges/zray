const std = @import("std");
const generated = @import("rx_options").generated_graph;
const rule = if (generated) @import("generated_rx_store_prepare") else void;
const Form = if (generated) rule.Input else enum { Definition, Field, Program, TypeContext };

const Step = if (generated) std.meta.Child(rule.Output) else enum {
    Done,
    CollectLayout,
    ResolveTypes,
    PrepareValues,
    CompileObjects,
    PublishDefinition,
    ReadFieldAttributes,
    ParseField,
    CompileField,
    RecordField,
    LinkField,
    ResolveObjectType,
    CheckLinks,
    BuildProgram,
    AnalyzeOwnership,
    VerifyProgram,
    CheckTypes,
    CheckNativeTypes,
    CheckNominalTypes,
    CheckAliases,
};

const capacity = 5;

pub fn steps(comptime form: Form) [capacity]Step {
    var buffer: [256]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&buffer);
    const sequence = if (generated) rule.executeValue(scratch.allocator(), form) catch unreachable else seed(form);
    var result: [capacity]Step = @splat(.Done);

    @memcpy(result[0..sequence.len], sequence);

    return result;
}

fn seed(comptime form: Form) []const Step {
    return switch (form) {
        .Definition => &.{ .CollectLayout, .ResolveTypes, .PrepareValues, .CompileObjects, .PublishDefinition },
        .Field => &.{ .ReadFieldAttributes, .ParseField, .CompileField, .RecordField, .LinkField },
        .Program => &.{ .ResolveObjectType, .CheckLinks, .BuildProgram, .AnalyzeOwnership, .VerifyProgram },
        .TypeContext => &.{ .CheckTypes, .CheckNativeTypes, .CheckNominalTypes, .CheckAliases },
    };
}
