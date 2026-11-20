const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const Mode = @import("conversion.zig").Mode;
const view = @import("../../node/view.zig");
const planner = @import("generated_state_conversion_plan");
const PlanInput = std.meta.Child(planner.Input);
const PlanningMode = @FieldType(PlanInput, "mode");
const resources = @import("generated_state_conversion_resources");
const ResourceInput = std.meta.Child(resources.Input);

pub fn lower(self: *Lower, body: anytype, id: ir.TypeId, value: node.ExpressionId, mode: Mode) Lower.Error!node.ExpressionId {
    return lowerWithStorage(self, body, body, id, value, mode);
}

pub fn lowerWithStorage(self: *Lower, borrow_storage: anytype, body: anytype, id: ir.TypeId, value: node.ExpressionId, mode: Mode) Lower.Error!node.ExpressionId {
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const temporary = buffered.allocator();
    var boundary: Capture = undefined;
    const capture = captureBoundary(self, &boundary);
    const input = try prepareFor(self, temporary, id, value, mode, capture);
    const output = @import("generated_state_conversion_emit").executeIn(temporary, &input) catch |err| return failure(err);

    return apply(self, borrow_storage, body, output);
}

pub fn prepareFor(self: *Lower, temporary: std.mem.Allocator, id: ir.TypeId, value: node.ExpressionId, mode: Mode, capture: ?*const Capture) Lower.Error!Input {
    return prepareMode(self, temporary, id, value, switch (mode) {
        .value => .Value,
        .value_layout => .ValueLayout,
        .row_value => .RowValue,
        .pointer => .Pointer,
        .layout => .Layout,
        .row_layout => .RowLayout,
        .borrow => .Borrow,
        .view_value => .ViewValue,
        .view_layout => .ViewLayout,
    }, capture);
}

pub fn prepareMode(self: *Lower, temporary: std.mem.Allocator, id: ir.TypeId, value: node.ExpressionId, mode: PlanningMode, capture: ?*const Capture) Lower.Error!Input {
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(PlanInput, "types")), self.program.types);

    const request: PlanInput = .{
        .types = &types,
        .queries = zx.columns.slice(@FieldType(PlanInput, "queries"), self.state_plan.queries),
        .selected = self.state_plan.selected,
        .element_storage = self.state_plan.element_storage,
        .root = @backingInt(id),
        .mode = mode,
    };

    const plan = if (mode == .ViewValue or mode == .ViewLayout)
        try @import("view_plan.zig").build(self, temporary, &request)
    else
        planner.executeIn(temporary, &request) catch |err| return failure(err);

    return prepare(self, temporary, plan, value, capture);
}

pub const Input = std.meta.Child(@import("generated_state_conversion_emit").Input);
pub const Capture = std.meta.Child(@typeInfo(@FieldType(Input, "capture")).optional.child);
const Plan = std.meta.Child(planner.Output);

pub fn captureBoundary(self: *const Lower, storage: *Capture) ?*const Capture {
    const captured = self.capture orelse return null;

    storage.* = .{ .name = captured.name, .label = captured.label, .failure = @backingInt(captured.failure) };

    return storage;
}

fn prepare(self: *Lower, temporary: std.mem.Allocator, plan: *const Plan, value: node.ExpressionId, capture: ?*const Capture) Lower.Error!Input {
    const count = plan.types.len;
    const capacity = std.math.mul(usize, count, 3) catch return error.OutOfMemory;
    const buffer = try temporary.alloc(u32, capacity);
    const layouts = buffer[0..count];
    const targets = buffer[count..][0..count];
    const elements = buffer[count * 2 ..];
    const origins = try temporary.alloc([]const u8, count);
    const serial = self.serial;
    const declarations = self.task_declarations.count();
    const type_expression = @import("../types.zig");
    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    for (plan.types, plan.kinds, plan.modes, plan.count, layouts, targets, elements, origins) |type_id, kind, mode, children, *layout, *target, *element, *origin| {
        const selected: ir.TypeId = @fromBackingInt(type_id);

        const request: ResourceInput = .{
            .mode = zx.columns.view(@FieldType(ResourceInput, "mode"), mode),
            .operation = zx.columns.view(@FieldType(ResourceInput, "operation"), kind),
            .referenced = self.state_plan.referenced(selected),
            .has_children = children != 0,
        };

        const selection = zx.columns.invoke(resources.executeValue, fixed.allocator(), &request) catch unreachable;

        layout.* = @backingInt(try type_expression.resource(self, selected, selection.layout));
        target.* = if (selection.target == .None) layout.* else @backingInt(try type_expression.resource(self, selected, selection.target));
        element.* = if (selection.element == .None) 0 else @backingInt(try type_expression.resource(self, self.program.typeOf(selected).list, selection.element));
        origin.* = if (selection.origin) try @import("origin.zig").name(self, selected) else &.{};
    }

    std.debug.assert(serial == self.serial and declarations == self.task_declarations.count());

    return .{
        .plan = plan,
        .layouts = layouts,
        .targets = targets,
        .elements = elements,
        .origins = origins,
        .referenced = self.state_plan.borrowed,
        .value = @backingInt(value),
        .shared = self.shared_types,
        .capture = capture,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(self.builder.nodes.statements.tags.items.len),
        .field_base = @intCast(self.builder.nodes.field_columns.count()),
        .serial = self.serial,
    };
}

pub fn apply(self: *Lower, borrow_storage: anytype, body: anytype, output: anytype) Lower.Error!node.ExpressionId {
    if (!output.valid) return error.OutOfMemory;

    const expressions = view.join(output.expressions.*, output.forms.*);
    const statements = view.join(output.statements.*, output.variables.*);
    const storage = view.join(output.storage.*, output.variables.*);
    const borrowed = view.join(output.borrow_storage.*, output.variables.*);
    const flat = view.join(output.body.*, output.variables.*);
    @import("../../node/import_rows.zig").append(self.allocator, &self.builder.nodes.expressions, &expressions) catch |err| return imported(err);
    @import("../../node/import_selected.zig").append(self.allocator, &self.builder.nodes.statements, &statements) catch |err| return imported(err);

    try self.hoistReferences(&storage);
    @import("../../node/import_statements.zig").appendSelected(self.allocator, borrow_storage, &borrowed) catch |err| return imported(err);
    @import("../../node/import_statements.zig").appendSelected(self.allocator, body, &flat) catch |err| return imported(err);
    _ = @import("../../node/import_fields.zig").appendBorrowingText(self.allocator, &self.builder.nodes.field_columns, output.fields) catch |err| return imported(err);
    self.serial = @intCast(output.serial);
    self.uses_allocator = self.uses_allocator or output.uses_allocator;

    return @fromBackingInt(output.root);
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => @panic("invalid state conversion"),
    };
}

fn imported(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidAst => @panic("invalid state conversion AST"),
        else => unreachable,
    };
}
