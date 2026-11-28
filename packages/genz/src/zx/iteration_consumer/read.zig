const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const evaluation = @import("../expressions/evaluate.zig");
const lists = @import("../state_value/list.zig");
const rows = @import("../construction/publication.zig");
const entry = @import("generated_consumer_read");
const Input = std.meta.Child(entry.Input);
const Source = std.meta.Child(@FieldType(Input, "source"));

pub fn lower(self: *Lower, symbol: ir.SymbolId, root: ir.ExprId, state: node.ExpressionId) Lower.Error!node.ExpressionId {
    var arena = std.heap.ArenaAllocator.init(self.workspace);
    var storage: [1024]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&storage, arena.allocator());

    defer arena.deinit();

    const program: *const ir.Program = &self.program;
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(Source, "types")), program.types);

    const source: Source = .{
        .table = zx.columns.pointer(@FieldType(Source, "table"), &program.expressions),
        .types = &types,
        .selected = self.state_plan.selected,
        .queries = zx.columns.slice(@FieldType(Source, "queries"), self.state_plan.queries),
        .element_storage = self.state_plan.element_storage,
        .active = self.state_active,
        .root = @backingInt(root),
        .symbol = @backingInt(symbol),
    };

    const input: Input = .{
        .frame = @ptrCast(self),
        .writer = @ptrCast(self),
        .source = &source,
        .state = @backingInt(state),
    };

    const output = entry.executeIn(scratch.allocator(), &input) catch |err| return rows.failure(err);

    return @fromBackingInt(output);
}

pub fn projectLoopPath(handle: *anyopaque, row: u32, target: u32, length_type: ?u32) Lower.Error!u32 {
    const self = evaluation.borrow(handle);
    const current: node.ExpressionId = @fromBackingInt(target);
    const value = self.program.expression(@fromBackingInt(row));

    return @backingInt(switch (value.value) {
        .field => |field| try self.field(current, self.program.typeOf(self.program.expression(field.target).type_id).object.at(field.index).name),
        .tuple_field => |field| try self.field(current, try std.fmt.allocPrint(self.allocator, "{d}", .{field.index})),
        .index => |item| try lists.items(self, self.program.expression(item.target).type_id, current),
        .length => |child| try self.cast(@fromBackingInt(length_type.?), try self.field(try lists.items(self, self.program.expression(child).type_id, current), "len")),
        else => unreachable,
    });
}
