const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Nodes = @import("../../nodes.zig");
const remap = @import("../../nodes/remap.zig");
const Error = @import("../../model.zig").Error;
const columns = @import("columns.zig");
const generated = @import("generated_source_function_batch");
const Input = @typeInfo(@TypeOf(generated.executeState)).@"fn".param_types[1].?;
const Columns = @FieldType(Input, "target");
const Mappings = std.meta.Child(@FieldType(Input, "mappings"));
const Mapping = std.meta.Child(@FieldType(Mappings, "types"));
const Empty = std.meta.Child(@FieldType(Input, "empty"));
const stack_depth_slots = 2048 / @sizeOf(u32);

pub fn append(nodes: *const Nodes, storage: *ir.FunctionStorage, source: ir.FunctionTable, temporary: std.mem.Allocator) Error!void {
    const count = source.count();

    if (count == 0) return;
    try storage.reserve(nodes.allocator, count);

    var completed: [1]u64 = .{0};
    const progress: []u64 = &completed;

    defer columns.publish(Columns, storage, source, @intCast(completed[0]));

    const target = columns.borrow(Columns, storage.reservedTail(count), true);
    const source_columns = zx.columns.view(std.meta.Child(@FieldType(Input, "source")), source);
    const types = remap.typeMapping(Mapping, nodes.types);
    const functions = remap.idMapping(Mapping, nodes.functions);
    const natives = remap.idMapping(Mapping, nodes.native_modules);

    const input: Input = .{
        .source = &source_columns,
        .target = target,
        .mappings = &.{ .types = &types, .functions = &functions, .natives = &natives },
        .empty = &.{
            .control = zx.columns.pointer(@FieldType(Empty, "control"), (ir.ControlBody{}).control),
            .stores = zx.columns.pointer(@FieldType(Empty, "stores"), &ir.FunctionStorage.empty_stores),
        },
        .depths = undefined,
        .start = 0,
        .max_offset = std.math.maxInt(usize),
        .progress = @ptrCast(&progress),
    };

    var fixed: [stack_depth_slots]u32 = undefined;
    var dynamic: std.ArrayList(u32) = .empty;

    defer dynamic.deinit(temporary);

    var depths: []u32 = &fixed;

    while (true) {
        var request = input;

        request.start = completed[0];
        request.depths = .{ .items = depths, .storage = .owned };

        const output = generated.executeState(nodes.allocator, request) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidModule,
        };

        columns.checkBorrow(target, output.columns);
        std.debug.assert(output.depths.items.ptr == depths.ptr);

        if (completed[0] == count) return;
        if (output.needed == 0) return error.InvalidModule;
        try dynamic.ensureTotalCapacity(temporary, @intCast(output.needed));

        depths = dynamic.allocatedSlice();
    }
}
