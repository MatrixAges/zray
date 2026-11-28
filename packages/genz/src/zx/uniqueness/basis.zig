const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Flow = @import("flow.zig");
const Memo = @import("memo.zig");
const Slots = @import("slots.zig");
const Self = @This();
const generated = @import("genz_options").generated_analysis;
const analyzing_effects = if (generated) @import("generated_uniqueness_effects") else void;
const publication = @import("../construction/publication.zig");
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
        const Input = std.meta.Child(entry.Input);
        const Functions = std.meta.Child(@FieldType(Input, "functions"));
        const FlowRows = std.meta.Child(@typeInfo(@FieldType(Input, "flow")).optional.child);
        var functions: Functions = undefined;

        inline for (@typeInfo(Functions).@"struct".field_names) |name| {
            @field(functions, name) = zx.columns.slice(@FieldType(Functions, name), @field(program.functions, name));
        }

        const types = zx.columns.borrow(std.meta.Child(@FieldType(Input, "types")), &program.types);
        var input: Input = .{ .persistent = kept != null, .types = &types, .functions = &functions, .flow = null };
        const prepared = entry.executeIn(allocator, &input) catch |err| return publication.failure(err);
        const plan = prepared.plan.?;
        const slots = @import("slots/generated.zig").bind(program.types, plan.slots.*);
        const contents = if (plan.hash) try identity.contents(allocator, &program) else &.{};
        const digest: [32]u8 = if (plan.hash) identity.types(program.types) else @splat(0);
        const flow = try Flow.create(allocator, workspace, program, slots, plan.slots.texts, contents, digest, kept);
        const rows: FlowRows = .{ .held = flow.held, .written = flow.written };
        input.flow = &rows;

        const completed = entry.executeIn(allocator, &input) catch |err| return publication.failure(err);
        const effects = completed.effects.?;

        return .{
            .slots = slots,
            .flow = flow,
            .return_only = effects.return_only,
            .effects = zx.columns.view(Effects, effects),
            .contents = contents,
            .types = digest,
        };
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
