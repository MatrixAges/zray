const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const Mode = @import("conversion.zig").Mode;
const runner = @import("generated_prepare_state_conversion");
const Request = std.meta.Child(runner.Input);
const View = std.meta.Child(@FieldType(Request, "view"));
const Source = std.meta.Child(@FieldType(View, "source"));
const Conversion = std.meta.Child(@FieldType(Source, "source"));
const Resources = std.meta.Child(@FieldType(Request, "resources"));
const emitter = @import("generated_state_conversion_emit");
const Call = std.meta.Child(emitter.Input);
pub const Input = std.meta.Child(@FieldType(Call, "conversion"));
pub const Capture = std.meta.Child(std.meta.Child(@FieldType(Input, "capture")));
pub const PlanningMode = @FieldType(Conversion, "mode");

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
    const input = (try prepare(self, temporary, id, value, planningMode(mode), capture, true)) orelse return value;

    const call: Call = .{
        .frame = @ptrCast(self),
        .writer = @ptrCast(self),
        .binding = @ptrCast(borrow_storage),
        .body = @ptrCast(body),
        .conversion = &input,
    };

    const root = emitter.executeIn(temporary, &call) catch |err| return failure(err);

    return @fromBackingInt(root);
}

pub fn prepareMode(self: *Lower, temporary: std.mem.Allocator, id: ir.TypeId, value: node.ExpressionId, mode: PlanningMode, capture: ?*const Capture) Lower.Error!Input {
    return (try prepare(self, temporary, id, value, mode, capture, false)).?;
}

fn planningMode(mode: Mode) PlanningMode {
    return switch (mode) {
        inline else => |kind| @field(PlanningMode, @import("../../node/view.zig").pascal(@tagName(kind))),
    };
}

pub fn captureBoundary(self: *const Lower, storage: *Capture) ?*const Capture {
    const captured = self.capture orelse return null;

    storage.* = .{ .name = captured.name, .label = captured.label, .failure = @backingInt(captured.failure) };

    return storage;
}

fn prepare(self: *Lower, temporary: std.mem.Allocator, id: ir.TypeId, value: node.ExpressionId, mode: PlanningMode, capture: ?*const Capture, check_view: bool) Lower.Error!?Input {
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(Conversion, "types")), self.program.types);

    const conversion: Conversion = .{
        .types = &types,
        .queries = zx.columns.slice(@FieldType(Conversion, "queries"), self.state_plan.queries),
        .selected = self.state_plan.selected,
        .element_storage = self.state_plan.element_storage,
        .root = @backingInt(id),
        .mode = mode,
    };

    const source: Source = .{ .source = &conversion, .states = @ptrCast(self.state_types), .views = @ptrCast(self.view_types) };
    const view: View = .{ .frame = @ptrCast(self), .source = &source };

    const tables: std.meta.Child(@FieldType(Resources, "types")) = .{
        .abi_types = @ptrCast(self.abi_types),
        .abi_layouts = @ptrCast(self.abi_layouts),
        .state_types = source.states,
        .state_layouts = @ptrCast(self.state_layouts),
        .views = source.views,
    };

    const resources: Resources = .{
        .frame = view.frame,
        .types = &tables,
        .children = self.program.types.first,
        .referenced = self.state_plan.borrowed,
    };

    const serial = self.serial;
    const declarations = self.task_declarations.count();
    const request: Request = .{ .view = &view, .resources = &resources, .check_view = check_view };
    const prepared = (runner.executeIn(temporary, &request) catch |err| return failure(err)) orelse return null;

    std.debug.assert(serial == self.serial and declarations == self.task_declarations.count());

    return .{
        .plan = zx.columns.pointer(@FieldType(Input, "plan"), prepared.plan),
        .layouts = prepared.layouts,
        .targets = prepared.targets,
        .elements = prepared.elements,
        .origins = prepared.origins,
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

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => @panic("invalid state conversion"),
    };
}
