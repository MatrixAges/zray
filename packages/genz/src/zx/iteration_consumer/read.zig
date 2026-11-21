const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const aggregate = @import("../aggregate.zig");
const evaluation = @import("../expressions/evaluate.zig");
const lists = @import("../state_value/list.zig");
const entry = @import("generated_consumer_read");
const Input = std.meta.Child(entry.Input);

pub fn lower(self: *Lower, symbol: ir.SymbolId, root: ir.ExprId, state: node.ExpressionId) Lower.Error!node.ExpressionId {
    var arena = std.heap.ArenaAllocator.init(self.workspace);
    var storage: [256]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&storage, arena.allocator());

    defer arena.deinit();

    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(Input, "types")), self.program.types);
    const expressions: *const ir.ExpressionTable = &self.program.expressions;

    const input: Input = .{
        .table = zx.columns.pointer(@FieldType(Input, "table"), expressions),
        .types = &types,
        .selected = self.state_plan.selected,
        .queries = zx.columns.slice(@FieldType(Input, "queries"), self.state_plan.queries),
        .element_storage = self.state_plan.element_storage,
        .active = self.state_active,
        .root = @backingInt(root),
        .symbol = @backingInt(symbol),
    };

    const plan = zx.columns.invoke(entry.executeValue, scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    std.debug.assert(plan.valid);

    const evaluate = @import("generated_lower_loop_path");
    const Arguments = std.meta.Child(evaluate.Input);

    const arguments: Arguments = .{
        .frame = @ptrCast(self),
        .rows = plan.rows,
        .representations = zx.columns.slice(@FieldType(Arguments, "representations"), plan.representations),
        .length_type = if (plan.length_type) |raw| @backingInt(try self.typeExpr(@fromBackingInt(raw))) else null,
        .state = @backingInt(state),
    };

    return evaluation.invoke(evaluate, &arguments);
}

pub fn projectLoopPath(handle: *const anyopaque, row: u32, target: u32, length_type: ?u32) Lower.Error!u32 {
    const self = evaluation.borrow(handle);
    const current: node.ExpressionId = @fromBackingInt(target);
    const value = self.program.expression(@fromBackingInt(row));

    return @backingInt(switch (value.value) {
        .field => |field| try self.field(current, self.program.typeOf(self.program.expression(field.target).type_id).object.at(field.index).name),
        .tuple_field => |field| try self.field(current, try std.fmt.allocPrint(self.allocator, "{d}", .{field.index})),
        .index => |item| try @import("../intrinsics.zig").index(self, try lists.items(self, self.program.expression(item.target).type_id, current), try self.expr(item.index)),
        .length => |child| try self.cast(@fromBackingInt(length_type.?), try self.field(try lists.items(self, self.program.expression(child).type_id, current), "len")),
        else => unreachable,
    });
}

pub fn convertLoopPath(handle: *const anyopaque, row: u32, id: u32, conversion: evaluation.Api.PathConversion) Lower.Error!u32 {
    const self = evaluation.borrow(handle);
    const value = self.program.expression(@fromBackingInt(row));
    const projected: node.ExpressionId = @fromBackingInt(id);

    return @backingInt(switch (conversion) {
        .Plain => unreachable,
        .BorrowList => try lists.borrowed(self, value.type_id, projected),
        .ReadElement => converted: {
            var body: std.ArrayList(node.Statement) = .empty;
            const list = self.program.expression(value.value.index.target).type_id;
            const element = try @import("../state_value/elements.zig").read(self, &body, list, projected);

            break :converted try aggregate.finish(self, &body, element);
        },
        .Convert => converted: {
            var body: std.ArrayList(node.Statement) = .empty;
            const source = try aggregate.bind(self, &body, projected);
            const result = try @import("../state_value/conversion.zig").convert(self, &body, value.type_id, source, .value);

            break :converted try aggregate.finish(self, &body, result);
        },
    });
}
