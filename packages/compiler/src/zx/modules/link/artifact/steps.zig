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

pub fn entry(path: []const u8, function: *const @import("zx").ir.Function) bool {
    if (comptime !generated) return function.external == null and std.mem.eql(u8, path, function.file_name);

    const check = @import("generated_artifact_link_entry");
    const input: std.meta.Child(check.Input) = .{ .path = path, .file_name = function.file_name, .external = function.external != null };
    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    return check.executeValue(scratch.allocator(), &input) catch unreachable;
}
