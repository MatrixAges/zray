const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Context = @import("root.zig");
const Lower = @import("../lower.zig");

pub fn lower(context: *Context, id: ir.TypeId, value: node.ExpressionId) Lower.Error!node.ExpressionId {
    const self = context.lowering;
    const root_layout = try @import("types.zig").get(context, id);
    const planner = @import("generated_conversion_plan");
    const PlanInput = std.meta.Child(planner.Input);
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(PlanInput, "types")), self.program.types);

    const request: PlanInput = .{
        .types = &types,
        .layouts = zx.columns.slice(@FieldType(PlanInput, "layouts"), self.layout_types),
        .root = @backingInt(id),
        .inline_lists = context.inline_lists,
    };

    var fixed = std.heap.FixedBufferAllocator.init(&.{});
    const operation = zx.columns.invoke(@import("generated_conversion_operation").executeValue, fixed.allocator(), &request) catch unreachable;

    if (operation == .Value) return value;

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const plan = planner.executeIn(buffered.allocator(), &request) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    const serial = self.serial;
    const declarations = context.declarations.last;
    const prepared = try prepareResources(context, buffered.allocator(), plan.types, plan.kinds, root_layout, .input);

    std.debug.assert(serial == self.serial and std.meta.eql(declarations, context.declarations.last));

    const emitter = @import("generated_conversion_emit");
    const Input = std.meta.Child(emitter.Input);

    const input: Input = .{
        .plan = plan,
        .layouts = prepared.layouts,
        .elements = prepared.operands,
        .value = @backingInt(value),
        .capture = if (self.capture) |capture| &.{ .name = capture.name, .label = capture.label, .failure = @backingInt(capture.failure) } else null,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(self.builder.nodes.statements.tags.items.len),
        .field_base = @intCast(self.builder.nodes.field_columns.count()),
        .serial = self.serial,
    };

    const output = emitter.executeIn(buffered.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    if (!output.valid) return error.OutOfMemory;

    const result = try apply(context, output);
    const view = @import("../../node/view.zig");
    const prefix = view.join(output.declarations.*, output.variables.*);

    @import("../../node/import_statements.zig").append(self.allocator, context.declarations, &prefix) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidAst => unreachable,
    };

    return result;
}

const ResourceDirection = enum { input, returned };
const resource_entry = @import("generated_iteration_conversion_resources");
const ResourceInput = std.meta.Child(resource_entry.Input);
const ResourceSelection = @typeInfo(@typeInfo(@TypeOf(resource_entry.executeValue)).@"fn".return_type.?).error_union.payload;
const Resource = @FieldType(ResourceSelection, "base");
const Operation = @FieldType(ResourceInput, "operation");
const Requirement = @typeInfo(@FieldType(ResourceInput, "requirement")).optional.child;

fn selections(comptime direction: ResourceDirection) [@typeInfo(if (direction == .input) Operation else Requirement).@"enum".field_names.len]ResourceSelection {
    @setEvalBranchQuota(20000);

    var table: [@typeInfo(if (direction == .input) Operation else Requirement).@"enum".field_names.len]ResourceSelection = undefined;

    for (std.enums.values(if (direction == .input) Operation else Requirement)) |kind| {
        const input: ResourceInput = .{
            .operation = if (direction == .input) kind else .Value,
            .requirement = if (direction == .returned) kind else null,
        };

        var fixed = std.heap.FixedBufferAllocator.init(&.{});

        table[@backingInt(kind)] = zx.columns.invoke(resource_entry.executeValue, fixed.allocator(), &input) catch unreachable;
    }

    return table;
}

pub fn prepareResources(context: *Context, allocator: std.mem.Allocator, types: []const u32, requests: anytype, root: node.ExpressionId, comptime direction: ResourceDirection) Lower.Error!struct { layouts: []const u32, operands: []const u32 } {
    const table = comptime selections(direction);
    const layouts = try allocator.alloc(u32, types.len);
    const operands = try allocator.alloc(u32, types.len);

    for (types, requests, layouts, operands, 0..) |raw, request, *layout, *operand, index| {
        const id: ir.TypeId = @fromBackingInt(raw);
        const selection = table[@backingInt(request)];
        const base = if (index == 0) root else try readResource(context, id, selection.base);
        layout.* = @backingInt(if (selection.replacement == .None) base else try readResource(context, id, selection.replacement));
        operand.* = @backingInt(try readResource(context, id, selection.operand));
    }

    return .{ .layouts = layouts, .operands = operands };
}

fn readResource(context: *Context, id: ir.TypeId, resource: Resource) Lower.Error!node.ExpressionId {
    const self = context.lowering;
    const types = @import("types.zig");

    return switch (resource) {
        .None => @fromBackingInt(0),
        .IterationType => types.get(context, id),
        .IterationItem => types.get(context, self.program.typeOf(id).list),
        .NativeLayout => self.layoutExpr(id),
        .NativeType => self.typeExpr(id),
        .StateLayout => @import("../types.zig").get(self, self.state_layouts, id),
        .Invalid => unreachable,
    };
}

pub fn apply(context: *Context, output: anytype) Lower.Error!node.ExpressionId {
    const self = context.lowering;
    const view = @import("../../node/view.zig");
    const expressions = view.join(output.expressions.*, output.forms.*);

    try append(self, &self.builder.nodes.expressions, &expressions);
    try append(self, &self.builder.nodes.statements, output.statements);

    _ = @import("../../node/import_fields.zig").appendBorrowingText(self.allocator, &self.builder.nodes.field_columns, output.fields) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidAst => unreachable,
    };

    self.serial = @intCast(output.serial);
    self.uses_allocator = self.uses_allocator or output.uses_allocator;

    return @fromBackingInt(output.root);
}

fn append(self: *Lower, target: anytype, source: anytype) Lower.Error!void {
    @import("../../node/import_rows.zig").append(self.allocator, target, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidAst => unreachable,
    };
}
