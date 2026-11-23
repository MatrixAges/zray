const std = @import("std");
const zx = @import("zx");
const frontend = @import("frontend");
const ir = zx.ir;
const Builder = @import("../builder.zig");
const Module = @import("../../module.zig");
const table = frontend.project.artifact.function_table;
const Nodes = frontend.ArtifactNodes;
const Range = @typeInfo(@typeInfo(@TypeOf(table.range)).@"fn".return_type.?).error_union.payload;
const Self = @This();

const Addition = struct {
    tail: ir.FunctionTable,
    range: Range,
    nodes: Nodes,
};

id: ir.FunctionId,
needs_initializers: bool,
addition: ?Addition = null,
pub fn prepare(builder: *const Builder, call: *const Module.Call, output: *Self) Builder.Error!void {
    const initializers = call.store_initializers;
    const prefix = builder.base_functions;

    if (call.function_id) |id| {
        if (call.callee_suffix != null) return error.InvalidModule;

        const checked = initializers.len == 0 or (initializers.len <= builder.checked_initializers.len and initializers.ptr == builder.checked_initializers.ptr);
        const reuse = @import("../functions.zig").shared(&builder.base_functions, @backingInt(id), &call.callee, checked);

        if (reuse == .Invalid) return error.InvalidModule;

        output.* = .{ .id = id, .needs_initializers = reuse == .CheckInitializers };

        return;
    }

    const extension = try table.extend(call.callee.functions, prefix, call.callee_suffix, null);
    const first = std.math.add(usize, prefix.count(), builder.functions.count()) catch return error.OutOfMemory;
    const count = std.math.cast(usize, extension.total) orelse return error.OutOfMemory;
    const range = try table.range(first, count, prefix.count(), builder.types.count(), builder.native_modules.count());

    output.* = .{
        .id = @fromBackingInt(range.root),
        .needs_initializers = initializers.len != 0,
        .addition = .{
            .tail = extension.tail,
            .range = range,
            .nodes = .{
                .allocator = builder.allocator,
                .types = .{ .identity = range.types },
                .functions = .{ .range = .{
                    .first = range.first,
                    .count = range.count,
                    .prefix = range.prefix,
                } },
                .native_modules = .{ .range = .{ .first = 0, .count = range.native_modules } },
            },
        },
    };
}

pub fn appendTail(self: *Self, builder: *Builder) Builder.Error!void {
    const addition = &self.addition.?;

    addition.nodes.appendFunctions(&builder.functions, addition.tail, builder.linking_scratch.allocator()) catch |err| return Builder.linkFailure(err);
}

pub fn linkInitializers(self: *const Self, builder: *Builder, call: *const Module.Call) Builder.Error!void {
    const range: Builder.InitializerRange = if (self.addition) |*addition| .{
        .first = addition.range.first,
        .count = addition.range.count,
        .prefix = addition.range.prefix,
    } else .{ .count = builder.base_functions.count() + builder.functions.count() };

    try builder.mergeInitializers(call.store_initializers, range);
}

pub fn appendEntry(self: *Self, builder: *Builder, call: *const Module.Call) Builder.Error!void {
    self.addition.?.nodes.appendProgram(&builder.functions, &call.callee, builder.linking_scratch.allocator()) catch |err| return Builder.linkFailure(err);
}
