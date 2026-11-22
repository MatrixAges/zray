const std = @import("std");
const ir = @import("zx").ir;
const Flow = @import("flow.zig");
const Memo = @import("memo.zig");
const Slots = @import("slots.zig");
const Self = @This();
const generated = @import("genz_options").generated_analysis;
const analyzing_effects = if (generated) @import("generated_uniqueness_effects") else void;
const identity = @import("identity.zig");
const Error = std.mem.Allocator.Error;
pub const Effects = if (generated) analyzing_effects.Output else void;

/// What every body analysis of a program reads and none writes: the list slots of each type, and which input slots
/// each function's output can hold and its updates may write in place. They depend only on the types and function
/// bodies, so one basis serves the whole program and every entry body later analyzed against it.
slots: Slots,
flow: Flow,
return_only: []const bool,
effects: Effects,
/// The content of each function body, hashed when `memo` keeps analyses across programs; empty otherwise.
contents: []const [32]u8 = &.{},
/// The digest of the type table, taken with `contents`.
types: [32]u8 = @splat(0),
pub fn create(allocator: std.mem.Allocator, workspace: std.mem.Allocator, program: ir.Program, memo: ?*Memo) Error!Self {
    const kept = if (memo) |value| if (value.persistent) value else null else null;

    if (generated) {
        const entry = @import("generated_basis_workflow");
        var result: Self = .{ .slots = undefined, .flow = undefined, .return_only = undefined, .effects = undefined };

        var frame: Frame = .{
            .allocator = allocator,
            .workspace = workspace,
            .program = &program,
            .memo = kept,
            .result = &result,
        };

        const input: std.meta.Child(entry.Input) = .{ .work = @ptrCast(&frame), .persistent = kept != null };

        try @import("../expressions/evaluate.zig").execute(entry, &input);

        return result;
    }

    const built = try Slots.init(allocator, program.types);
    const contents = if (kept != null) try identity.contents(allocator, &program) else &.{};
    const types: [32]u8 = if (kept != null) identity.types(program.types) else @splat(0);

    return .{
        .slots = built.slots,
        .flow = try Flow.create(allocator, workspace, program, built.slots, built.texts, contents, types, kept),
        .return_only = try @import("return_only.zig").create(allocator, program),
        .effects = {},
        .contents = contents,
        .types = types,
    };
}

const Frame = struct {
    allocator: std.mem.Allocator,
    workspace: std.mem.Allocator,
    program: *const ir.Program,
    memo: ?*Memo,
    result: *Self,
    texts: []const bool = undefined,
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn buildBasisSlots(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const built = try Slots.init(frame.allocator, frame.program.types);
    frame.result.slots = built.slots;
    frame.texts = built.texts;
}

pub fn hashBasis(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    frame.result.contents = try identity.contents(frame.allocator, frame.program);
    frame.result.types = identity.types(frame.program.types);
}

pub fn buildBasisFlow(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const result = frame.result;

    result.flow = try Flow.create(frame.allocator, frame.workspace, frame.program.*, result.slots, frame.texts, result.contents, result.types, frame.memo);
}

pub fn buildBasisReturns(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    frame.result.return_only = try @import("return_only.zig").create(frame.allocator, frame.program.*);
}

pub fn buildBasisEffects(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const result = frame.result;

    result.effects = analyzing_effects.executeIn(frame.allocator, &.{
        .held = result.flow.held,
        .written = result.flow.written,
        .return_only = result.return_only,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
}

pub fn lists(allocator: std.mem.Allocator, slots: Slots, type_id: ir.TypeId) std.mem.Allocator.Error![]const ir.TypeId {
    var result: std.ArrayList(ir.TypeId) = .empty;

    for (0..slots.count(type_id)) |slot| {
        const list = slots.listType(type_id, @intCast(slot));

        if (std.mem.indexOfScalar(ir.TypeId, result.items, list) == null) try result.append(allocator, list);
    }

    return result.items;
}

/// A splice from the front hands its removed prefix back in the target's buffer, retracting the frontier as a pop does.
pub fn prefix(expressions: ir.ExpressionTable, operation: anytype) bool {
    if (operation.kind != .splice) return false;

    const start = expressions.get(operation.arguments[0]).value;

    return start == .integer and start.integer == 0;
}
