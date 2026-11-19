const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const memory = zx.memory;
const projection = @import("../borrow.zig");
const bodies_entry = @import("generated_ir_compare_bodies");
const Input = std.meta.Child(bodies_entry.Input);
const Table = std.meta.Child(std.meta.Elem(@FieldType(Input, "tables")));
const Column = std.meta.Child(std.meta.Elem(@FieldType(Table, "columns")));

const groups = .{
    .{ ir.StoreTable, "stores" },
    .{ ir.SymbolTable, "symbols" },
    .{ ir.ExpressionTable, "expressions" },
    .{ ir.ControlTable, "control" },
    .{ ir.ContractTable, "contracts" },
};

pub fn bodies(left: *const ir.FunctionTable, right: *const ir.FunctionTable, first: usize, end: usize) bool {
    if (first == end) return true;

    var a: [groups.len]memory.ReferenceRows = undefined;
    var b: [groups.len]memory.ReferenceRows = undefined;
    var tables: [groups.len]Table = undefined;
    var views: [groups.len]*const Table = undefined;

    inline for (groups, 0..) |group, index| {
        const ColumnTable, const field = group;
        a[index] = memory.borrowReferenceRows(@field(left, field));
        b[index] = memory.borrowReferenceRows(@field(right, field));

        tables[index] = .{
            .left = @ptrCast(&a[index]),
            .right = @ptrCast(&b[index]),
            .columns = projection.referenced(Column, ColumnTable),
        };

        views[index] = &tables[index];
    }

    const Contracts = std.meta.Child(@FieldType(Input, "contracts"));
    const contract_slot = groups.len - 1;
    const compare = contractView(Contracts, &a[contract_slot], &b[contract_slot]);
    const input: Input = .{ .tables = &views, .contracts = &compare, .first = first, .end = end };
    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(bodies_entry.executeValue, fixed.allocator(), &input) catch unreachable;
}

pub fn ContractView(comptime Contracts: type) type {
    return struct {
        left_rows: [1]*const ir.ContractTable,
        right_rows: [1]*const ir.ContractTable,
        left: memory.ReferenceRows,
        right: memory.ReferenceRows,
        input: Contracts,
        pub fn init(self: *@This(), left: *const ir.ContractTable, right: *const ir.ContractTable) void {
            self.left_rows = .{left};
            self.right_rows = .{right};
            self.left = memory.borrowReferenceRows(&self.left_rows);
            self.right = memory.borrowReferenceRows(&self.right_rows);
            self.input = contractView(Contracts, &self.left, &self.right);
        }
    };
}

fn contractView(comptime Contracts: type, left: *const memory.ReferenceRows, right: *const memory.ReferenceRows) Contracts {
    const Layout = std.meta.Child(@FieldType(Contracts, "layout"));
    const Spec = std.meta.Child(std.meta.Elem(@FieldType(Layout, "symbol_columns")));

    const Definition = struct {
        const layout: Layout = .{
            .symbols = @offsetOf(ir.ContractTable, "symbols"),
            .expressions = @offsetOf(ir.ContractTable, "expressions"),
            .symbol_columns = projection.referenced(Spec, ir.SymbolTable),
            .expression_columns = projection.referenced(Spec, ir.ExpressionTable),
        };
    };

    return .{ .left = @ptrCast(left), .right = @ptrCast(right), .layout = &Definition.layout };
}
