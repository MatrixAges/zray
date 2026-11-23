const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Self = @This();
const Registry = @import("frontend").project.compiled.InitializerRegistry;
pub const InitializerRange = Registry.Range;
const StoreInitializer = @import("frontend").project.compiled.StoreInitializer;
pub const Error = std.mem.Allocator.Error || error{ InvalidModule, UnreachableFlow, IncompleteFlow };

allocator: std.mem.Allocator,
types: ir.TypeTable,
native_modules: ir.NativeModuleTable,
symbols: ir.SymbolStorage = .{},
expressions: ir.ExpressionStorage = .{},
functions: ir.FunctionStorage = .{},
base_functions: ir.FunctionTable = .{},
store_initializers: Registry = .{},
checked_initializers: []const StoreInitializer = &.{},
stores: ir.StoreStorage = .{},
bindings: std.ArrayList(ir.SymbolId) = .empty,
linking_scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
pub fn symbol(self: *Self, name: []const u8, type_id: ir.TypeId, span: zx.Span) std.mem.Allocator.Error!ir.SymbolId {
    const id: ir.SymbolId = @fromBackingInt(@intCast(self.symbols.count()));

    try self.symbols.append(self.allocator, .{ .name = try self.allocator.dupe(u8, name), .type_id = type_id, .span = span });

    return id;
}

pub fn seedExpression(self: *Self, value: ir.Expression) std.mem.Allocator.Error!ir.ExprId {
    const id: ir.ExprId = @fromBackingInt(@intCast(self.expressions.count()));
    _ = try self.expressions.append(self.allocator, value);

    return id;
}

pub fn expressionSpan(self: *const Self, id: ir.ExprId) zx.Span {
    const index = @backingInt(id);

    return .{ .start = @intCast(self.expressions.span_start.items[index]), .end = @intCast(self.expressions.span_end.items[index]) };
}

pub fn expressionType(self: *const Self, id: ir.ExprId) ir.TypeId {
    return @fromBackingInt(self.expressions.types.items[@backingInt(id)]);
}

pub fn linkFailure(err: anyerror) Error {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidModule;
}

pub fn appendStore(self: *Self, value: ir.StoreSlot) std.mem.Allocator.Error!u32 {
    const id: u32 = @intCast(self.stores.count());

    try self.stores.append(self.allocator, .{ .path = try self.allocator.dupe(u8, value.path), .type_id = value.type_id, .readable = value.readable, .writable = value.writable });

    return id;
}

pub fn seedStore(self: *Self, value: ir.StoreSlot) Error!u32 {
    for (0..self.stores.count()) |index| {
        const slot = self.stores.at(index);

        if (!std.mem.eql(u8, slot.path, value.path)) continue;
        if (slot.type_id != value.type_id) return error.InvalidModule;

        self.stores.readable.items[index] = slot.readable or value.readable;
        self.stores.writable.items[index] = slot.writable or value.writable;

        return @intCast(index);
    }

    return self.appendStore(value);
}

pub fn mergeInitializers(self: *Self, values: []const StoreInitializer, range: Registry.Range) Error!void {
    self.store_initializers.merge(self.allocator, values, range, &.{ .prefix = &self.base_functions, .local = &self.functions }, false) catch |err| return linkFailure(err);
}
