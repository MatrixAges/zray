const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;

pub fn View(comptime Destination: type) type {
    const Row = std.meta.Child(@typeInfo(@FieldType(Destination, "shape")).optional.child);

    return struct {
        slots: [@typeInfo(Row).@"struct".field_names.len]*anyopaque,
        columns: zx.memory.ColumnSet,
        input: Destination,
        pub fn init(self: *@This(), allocator: *const std.mem.Allocator, functions: *ir.FunctionStorage) void {
            self.slots = zx.memory.bindColumnSet(Row, true, functions);
            self.columns = &self.slots;

            self.input = .{
                .storage = @ptrCast(&self.columns),
                .shape = null,
                .maximum_count = std.math.maxInt(u32),
                .resource = @ptrCast(allocator),
            };
        }
    };
}

pub fn empty(comptime Body: type) Body {
    return .{
        .symbols = zx.columns.pointer(@FieldType(Body, "symbols"), &ir.FunctionStorage.empty_symbols),
        .expressions = zx.columns.pointer(@FieldType(Body, "expressions"), &ir.FunctionStorage.empty_expressions),
        .contracts = zx.columns.pointer(@FieldType(Body, "contracts"), &ir.FunctionStorage.empty_contracts),
        .control = zx.columns.pointer(@FieldType(Body, "control"), (ir.ControlBody{}).control),
        .stores = zx.columns.pointer(@FieldType(Body, "stores"), &ir.FunctionStorage.empty_stores),
    };
}
