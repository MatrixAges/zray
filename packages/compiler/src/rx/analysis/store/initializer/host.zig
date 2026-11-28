const std = @import("std");
const rx = @import("rx");
const zx = @import("zx");
const Declarations = @import("../../project/declarations.zig");
const State = @import("state.zig");
const object = @import("object.zig");
const entry = @import("generated_rx_compile_store_initializer");
const Request = std.meta.Child(entry.Input);
const Value = @import("../initializer.zig").Value;
const Error = std.mem.Allocator.Error;
const StoreState = std.meta.Child(@FieldType(entry.zx_pending, "store_0"));

const Frame = struct {
    state: *State,
    store_0: *StoreState,
    snapshot: *std.meta.Child(StoreState),
    pub fn commit(frame: *Frame, pending: anytype) zx.Error!void {
        const effect = pending.store_0 orelse return;
        const state = frame.state;

        switch (effect.step) {
            .Prepare => try state.prepare(@intCast(effect.index.?), false),
            .Evaluate => {
                try state.openField(@intCast(effect.index.?), Declarations.attribute(effect.name.?), Declarations.attribute(effect.value.?));

                frame.snapshot.* = effect.*;
                frame.snapshot.valid = try state.compileField();
                frame.store_0.* = frame.snapshot;
            },
            .Record => try state.recordField(@intCast(effect.index.?), false),
            .Link => {
                frame.snapshot.* = effect.*;
                frame.snapshot.valid = try state.linkField(@intCast(effect.index.?));
                frame.store_0.* = frame.snapshot;
            },
            .Release => state.releaseField(),
            .Resolve => {
                try state.resolveType();

                frame.snapshot.* = effect.*;
                frame.snapshot.source = state.names;
                frame.snapshot.canonical = state.table.?.get(state.output).object.names;
                frame.store_0.* = frame.snapshot;
            },
            .InvalidLink => return state.invalidLink(),
            .Finish => {
                const root = try object.appendPositioned(&state.builder, state.output, effect.positions.?, state.evaluation, State.span);

                try state.finishProgram(root);
                try state.analyzeOwnership();
                try state.verifyProgram();
            },
        }
    }
};

pub fn run(state: *State) Error!Value {
    const options = state.options;
    const Fields = std.meta.Child(@FieldType(Request, "fields"));
    const Layout = std.meta.Child(@FieldType(Fields, "layout"));

    var snapshot: std.meta.Child(StoreState) = .{
        .step = .Prepare,
        .index = null,
        .name = null,
        .value = null,
        .positions = null,
        .valid = false,
        .source = &.{},
        .canonical = &.{},
    };

    var store: StoreState = &snapshot;
    var frame: Frame = .{ .state = state, .store_0 = &store, .snapshot = &snapshot };

    const input: Request = .{
        .layout = &.{ .offsets = options.layout.offsets, .next = options.layout.next },
        .fields = &.{
            .pointers = std.mem.sliceAsBytes(options.layout.fields),
            .width = @sizeOf(*const rx.ast.Node),
            .layout = &comptime rx.astLayout(Layout),
        },
        .first = options.first,
    };

    var buffer: [4096]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, state.temporary);

    entry.executeIn(scratch.allocator(), &input, &frame) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        error.InvalidSource => return .{ .diagnostic = try state.report() },
        else => unreachable,
    };

    return if (state.diagnostic) |issue| .{ .diagnostic = issue } else .{ .program = state.program };
}
