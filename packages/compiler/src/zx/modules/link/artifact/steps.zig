const std = @import("std");
const generated = @import("parser_options").generated_parser;
const rule = if (generated) @import("generated_artifact_link_steps") else void;
const Phase = if (generated) rule.Input else enum { Graph, Module };

const Step = if (generated) std.meta.Child(rule.Output) else enum {
    PrepareGraph,
    MergeTypes,
    LinkDependencies,
    LinkEntry,
    PublishProgram,
    VerifyLayout,
    ReserveMappings,
    CheckNames,
    CheckConstants,
    LinkNativeModules,
    BindSignatures,
    CheckImports,
    ResolveBody,
};

pub fn run(comptime phase: Phase) if (phase == .Graph) [5]Step else [8]Step {
    var buffer: [256]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&buffer);
    const sequence = if (generated) rule.executeValue(scratch.allocator(), phase) catch unreachable else seed(phase);
    const count = if (phase == .Graph) 5 else 8;

    if (sequence.len != count) @panic("invalid artifact link schedule length");

    return sequence[0..count].*;
}

fn seed(comptime phase: Phase) []const Step {
    return switch (phase) {
        .Graph => &.{ .PrepareGraph, .MergeTypes, .LinkDependencies, .LinkEntry, .PublishProgram },
        .Module => &.{ .VerifyLayout, .ReserveMappings, .CheckNames, .CheckConstants, .LinkNativeModules, .BindSignatures, .CheckImports, .ResolveBody },
    };
}

pub fn entry(path: []const u8, function: *const @import("zx").ir.Function) bool {
    if (comptime !generated) return function.external == null and std.mem.eql(u8, path, function.file_name);

    const check = @import("generated_artifact_link_entry");
    const input: std.meta.Child(check.Input) = .{ .path = path, .file_name = function.file_name, .external = function.external != null };
    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    return check.executeValue(scratch.allocator(), &input) catch unreachable;
}
