const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const evaluation = @import("../expressions/evaluate.zig");
const lists = @import("../state_value/list.zig");
const entry = @import("generated_consumer_read");
const Input = std.meta.Child(entry.Input);
const Source = std.meta.Child(@FieldType(Input, "source"));

pub fn lower(self: *Lower, symbol: ir.SymbolId, root: ir.ExprId, state: node.ExpressionId) Lower.Error!node.ExpressionId {
    var arena = std.heap.ArenaAllocator.init(self.workspace);
    var storage: [256]u8 = undefined;
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

    const input: Input = .{ .frame = @ptrCast(self), .source = &source, .state = @backingInt(state) };
    const output = entry.executeIn(scratch.allocator(), &input) catch |err| return @import("../construction/publication.zig").failure(err);

    return @fromBackingInt(output);
}

pub fn requireLoopPath(valid: bool) void {
    std.debug.assert(valid);
}

pub fn projectLoopPath(handle: *anyopaque, row: u32, target: u32, length_type: ?u32) Lower.Error!u32 {
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

pub fn convertLoopPath(handle: *anyopaque, row: u32, id: u32, conversion: evaluation.Api.PathConversion) Lower.Error!u32 {
    const self = evaluation.borrow(handle);
    const value = self.program.expression(@fromBackingInt(row));
    const projected: node.ExpressionId = @fromBackingInt(id);

    return @backingInt(switch (conversion) {
        .Plain => unreachable,
        .BorrowList => try lists.borrowed(self, value.type_id, projected),
        .ReadElement => try @import("../state_value/elements.zig").expression(self, self.program.expression(value.value.index.target).type_id, projected),
        .Convert => try @import("../state_value/conversion.zig").read(self, value.type_id, projected),
    });
}
