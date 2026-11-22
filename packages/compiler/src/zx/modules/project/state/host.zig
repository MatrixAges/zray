const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Origins = @import("../../nominal_origins.zig");
const Context = @import("../../../analysis/analyze.zig").Context;
const enabled = @import("parser_options").generated_parser;

pub const State = struct {
    types: ir.TypeStorage,
    native_modules: ir.NativeModuleStorage,
    origins: Origins,
};

pub const Open = union(enum) {
    state: State,
    diagnostic: zx.Diagnostic,
};

const Frame = struct {
    allocator: std.mem.Allocator,
    context: *const Context,
    state: State = undefined,
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn open(allocator: std.mem.Allocator, context: *const Context) std.mem.Allocator.Error!Open {
    var frame: Frame = .{ .allocator = allocator, .context = context };
    const handle: *const anyopaque = @ptrCast(&frame);

    if (comptime enabled) {
        const generated = @import("generated_project_state_open");
        const Input = std.meta.Child(generated.Input);
        const table = ir.TypeTable.borrow(std.meta.Child(@FieldType(Input, "table")), context.types);
        const modules = zx.columns.pointer(@FieldType(Input, "modules"), &context.native_modules);
        const origins = Origins.Table.borrow(std.meta.Child(@FieldType(Input, "origins")), context.nominal_types);

        const input: Input = .{
            .state = @ptrCast(&frame),
            .table = &table,
            .modules = modules,
            .origins = &origins,
            .names = context.nominal_types.names,
            .scalar_count = std.enums.values(ir.Scalar).len,
            .maximum_count = std.math.maxInt(u32),
        };

        var empty = std.heap.FixedBufferAllocator.init(&.{});

        const admission = zx.columns.invoke(generated.executeValue, empty.allocator(), &input) catch |err| return switch (@as(anyerror, err)) {
            error.OutOfMemory => error.OutOfMemory,
            else => unreachable,
        };

        return switch (admission) {
            .Types => failure("invalid shared type table"),
            .Native => failure("invalid shared native module table"),
            .Nominal => failure("invalid shared nominal type table"),
            .Ready => .{ .state = frame.state },
        };
    }

    if (context.types.count() != 0 and !@import("../../../ir/type_rules.zig").validate(context.types)) return failure("invalid shared type table");
    if (!@import("../../native_context.zig").valid(context.types, context.native_modules)) return failure("invalid shared native module table");
    if (!try @import("../../../analysis/semantic/origins.zig").valid(context.types, context.nominal_types)) return failure("invalid shared nominal type table");
    try copyProjectTypes(handle);
    try copyProjectNatives(handle);
    try copyProjectOrigins(handle);

    return .{ .state = frame.state };
}

pub fn copyProjectTypes(handle: *const anyopaque) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);
    frame.state.types = try @import("../../../analysis/type_table.zig").storage(frame.allocator, frame.context.types);
}

pub fn copyProjectNatives(handle: *const anyopaque) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);
    frame.state.native_modules = try @import("../../native_context.zig").storage(frame.allocator, frame.context.native_modules);
}

pub fn copyProjectOrigins(handle: *const anyopaque) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);

    frame.state.origins = .{ .allocator = frame.allocator };

    try frame.state.origins.copyValidated(frame.state.types.view(), frame.context.nominal_types);
}

fn failure(message: []const u8) Open {
    return .{ .diagnostic = .{ .code = .contract, .span = .{ .start = 0, .end = 0 }, .message = message } };
}
