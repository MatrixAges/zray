const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const memory = zx.memory;
const named = @import("../../../../ir/canonical/validation/names/view.zig");

pub fn View(comptime Exports: type, comptime Destination: type) type {
    const Source = std.meta.Child(@FieldType(Exports, "source"));

    return struct {
        names: []const []const u8,
        ids: []const u32,
        slots: [@typeInfo(ir.FunctionStorage).@"struct".field_names.len]*usize,
        lengths: memory.ColumnLengths,
        source: Source,
        exports: Exports,
        destination: Destination,
        pub fn init(self: *@This(), modules: *ir.NativeModuleStorage, functions: *ir.FunctionStorage, module: ir.NativeModuleId, rows: *const named.Rows, count: usize) void {
            self.names = &.{};
            self.ids = &.{};
            self.slots = memory.borrowColumnLengths(functions);
            self.lengths = &self.slots;
            self.source = .{ .rows = @ptrCast(rows), .length = count };
            self.exports = .{ .source = &self.source, .names = @ptrCast(&self.names), .ids = @ptrCast(&self.ids) };
            self.destination = undefined;
            self.destination.module = @backingInt(module);
            self.destination.namespaces = @ptrCast(&modules.type_namespaces.items);
            self.destination.type_names = @ptrCast(&modules.type_names.items);
            self.destination.type_ids = @ptrCast(&modules.type_ids.items);
            self.destination.functions = @ptrCast(&self.lengths);
        }
        pub fn release(self: *const @This(), allocator: std.mem.Allocator) void {
            allocator.free(self.ids);
            allocator.free(self.names);
        }
    };
}
