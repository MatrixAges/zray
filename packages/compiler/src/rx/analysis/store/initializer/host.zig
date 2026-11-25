const std = @import("std");
const rx = @import("rx");
const zx = @import("zx");
const Declarations = @import("../../project/declarations.zig");
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
    const Fields = std.meta.Child(@FieldType(Request, "fields"));
    const Layout = std.meta.Child(@FieldType(Fields, "layout"));
    var frame: Frame = .{ .state = state };

    const input: Request = .{
        .frame = @ptrCast(&frame),
        .layout = &.{ .offsets = options.layout.offsets, .next = options.layout.next },
        .fields = &.{
            .pointers = std.mem.sliceAsBytes(options.layout.fields),
            .width = @sizeOf(*const rx.ast.Node),
            .layout = &comptime rx.astLayout(Layout),
        },
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

fn borrow(handle: *anyopaque) *Frame {
    return @ptrCast(@alignCast(handle));
}

pub fn prepareStoreInitializer(handle: *anyopaque, count: u64) Error!void {
    try borrow(handle).state.prepare(@intCast(count), false);
}

pub fn evaluateStoreField(handle: *anyopaque, row: u64, name: []const u8, value: []const u8) Error!bool {
    const state = borrow(handle).state;

    try state.openField(@intCast(row), Declarations.attribute(name), Declarations.attribute(value));

    return state.compileField();
}

pub fn recordStoreField(handle: *anyopaque, position: u64) Error!void {
    try borrow(handle).state.recordField(@intCast(position), false);
}

pub fn linkStoreField(handle: *anyopaque, position: u64) Error!bool {
    return borrow(handle).state.linkField(@intCast(position));
}

pub fn releaseStoreField(handle: *anyopaque) void {
    borrow(handle).state.releaseField();
}

pub fn resolveStoreInitializer(handle: *anyopaque, invalid: bool) zx.Error!void {
    const frame = borrow(handle);
    const state = frame.state;

    try state.resolveType();
    if (invalid) return state.invalidLink();

    frame.object.bind(state);
}

pub fn finishStoreInitializer(handle: *anyopaque, root: u32) zx.Error!void {
    const state = borrow(handle).state;

    try state.finishProgram(@fromBackingInt(root));
    try state.analyzeOwnership();
    try state.verifyProgram();
}
