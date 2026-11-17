const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Nodes = @import("../../../artifact/nodes.zig");
const Module = @import("../../../artifact/model.zig").Module;
const Error = @import("../../../artifact/model.zig").Error;
const rule = @import("generated_artifact_body_publication");
const Input = std.meta.Child(rule.Input);

pub fn publish(nodes: *Nodes, module: *const Module, storage: *ir.FunctionStorage, temporary: std.mem.Allocator, mapping: []?ir.FunctionId, linked: *?ir.FunctionId, comptime entry: bool) Error!?Nodes.FunctionEntry {
    const body = if (module.function) |*function| function else return null;
    const first = storage.count();

    const input: Input = .{
        .body = &.{ .path = module.path, .file_name = body.file_name, .external = body.external != null },
        .entry = entry,
        .stores = module.stores.count(),
        .first = first,
        .slot = module.functions.count(),
        .target = @ptrCast(&mapping),
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const placement = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch return error.InvalidModule;

    return switch (placement) {
        .Absent, .Invalid => error.InvalidModule,
        .Append => published: {
            try nodes.appendFunction(storage, body, temporary);

            linked.* = @fromBackingInt(@intCast(first));

            break :published null;
        },
        .Retain => try nodes.functionEntry(body.*, if (entry) @fromBackingInt(@intCast(first)) else null, .unchecked),
    };
}
