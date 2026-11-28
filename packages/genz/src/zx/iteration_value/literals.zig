const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const failure = @import("../construction/publication.zig").failure;
const Context = @import("root.zig");
const Lower = @import("../lower.zig");
const enabled = @import("genz_options").generated_analysis;
const entry = if (enabled) @import("generated_iteration_literals") else struct {};
const Input = if (enabled) std.meta.Child(entry.Input) else void;
const Bindings = if (enabled) @FieldType(std.meta.Child(@import("operands.zig").Output), "bindings") else void;
pub const Mode = if (enabled) @FieldType(Input, "mode") else enum { Object, Tuple, List };

const Request = struct {
    mode: Mode,
    type_id: ir.TypeId,
    layout: node.ExpressionId,
    element: node.ExpressionId = @fromBackingInt(0),
    bindings: Bindings,
    field_indices: []const u32 = &.{},
    field_values: []const u32 = &.{},
    evaluation: []const ir.ExprId = &.{},
    prior: []const u64 = &.{},
};

pub noinline fn lower(context: *Context, args: Request) Lower.Error!node.ExpressionId {
    const self = context.lowering;
    const Counter = std.meta.Child(@FieldType(Input, "reads"));
    const Index = std.meta.Child(@FieldType(Counter, "index"));
    const Bases = std.meta.Child(@FieldType(Input, "bases"));
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(Input, "types")), self.program.types);
    const index = context.reads.indexView(Index);
    const reads: Counter = .{ .index = &index, .values = context.reads.state.values.items };

    const bases: Bases = .{
        .capture = if (self.capture) |capture| &.{ .name = capture.name, .label = capture.label, .failure = @backingInt(capture.failure) } else null,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(self.builder.nodes.statements.tags.items.len),
        .field_base = @intCast(self.builder.nodes.field_columns.count()),
        .serial = self.serial,
    };

    comptime std.debug.assert(@typeInfo(ir.ExprId).@"enum".tag_type == u32);

    const input: Input = .{
        .writer = @ptrCast(self),
        .frame = @ptrCast(self),
        .mode = args.mode,
        .types = &types,
        .type_id = @backingInt(args.type_id),
        .layout = @backingInt(args.layout),
        .element = @backingInt(args.element),
        .bindings = zx.columns.pointer(@FieldType(Input, "bindings"), args.bindings),
        .field_indices = args.field_indices,
        .field_values = args.field_values,
        .evaluation = @as([*]const u32, @ptrCast(args.evaluation.ptr))[0..args.evaluation.len],
        .prior = args.prior,
        .reads = &reads,
        .bases = &bases,
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const result = entry.executeIn(memory.allocator(), &input) catch |err| return failure(err);

    return @fromBackingInt(result);
}
