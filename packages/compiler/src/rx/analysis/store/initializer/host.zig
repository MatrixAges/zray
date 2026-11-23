const std = @import("std");
const zx = @import("zx");
const State = @import("state.zig");
const Object = @import("object/binding.zig");
const entry = @import("generated_rx_compile_store_initializer");
const Request = std.meta.Child(entry.Input);
const Value = @import("../initializer.zig").Value;
const Error = std.mem.Allocator.Error;

const Frame = struct {
    state: *State,
    object: Object.frame(std.meta.Child(@FieldType(Request, "object"))) = .{},
};

pub fn run(state: *State) Error!Value {
    const options = state.options;
    var frame: Frame = .{ .state = state };

    const input: Request = .{
        .frame = @ptrCast(&frame),
        .layout = &.{ .offsets = options.layout.offsets, .next = options.layout.next },
        .first = options.first,
        .object = &frame.object.input,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    entry.executeValue(empty.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        error.InvalidSource => return .{ .diagnostic = try state.report() },
        else => unreachable,
    };

    return if (state.diagnostic) |issue| .{ .diagnostic = issue } else .{ .program = state.program };
}

fn borrow(handle: *const anyopaque) *Frame {
    return @ptrCast(@alignCast(@constCast(handle)));
}

pub fn prepareStoreInitializer(handle: *const anyopaque, count: u64) Error!void {
    try borrow(handle).state.prepare(@intCast(count), false);
}

pub fn evaluateStoreField(handle: *const anyopaque, row: u64) Error!bool {
    const state = borrow(handle).state;

    try state.openField(@intCast(row));

    return state.compileField();
}

pub fn recordStoreField(handle: *const anyopaque, position: u64) Error!void {
    try borrow(handle).state.recordField(@intCast(position), false);
}

pub fn linkStoreField(handle: *const anyopaque, position: u64) Error!bool {
    return borrow(handle).state.linkField(@intCast(position));
}

pub fn releaseStoreField(handle: *const anyopaque) void {
    borrow(handle).state.releaseField();
}

pub fn resolveStoreInitializer(handle: *const anyopaque, invalid: bool) zx.Error!void {
    const frame = borrow(handle);
    const state = frame.state;

    try state.resolveType();
    if (invalid) return state.invalidLink();

    frame.object.bind(state);
}

pub fn finishStoreInitializer(handle: *const anyopaque, root: u32) zx.Error!void {
    const state = borrow(handle).state;

    try state.finishProgram(@fromBackingInt(root));
    try state.analyzeOwnership();
    try state.verifyProgram();
}
