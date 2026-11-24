const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const memory = zx.memory;
const projection = @import("../borrow.zig");

pub const groups = .{
    .{ ir.StoreTable, "stores" },
    .{ ir.SymbolTable, "symbols" },
    .{ ir.ExpressionTable, "expressions" },
    .{ ir.ControlTable, "control" },
    .{ ir.ContractTable, "contracts" },
};

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

    return .{ .left = @ptrCast(left), .right = @ptrCast(right), .layout = contractLayout(Layout) };
}

pub fn contractLayout(comptime Layout: type) *const Layout {
    const Columns = std.meta.Child(@FieldType(Layout, "symbol_columns"));

    const Definition = struct {
        const layout: Layout = .{
            .symbols = @offsetOf(ir.ContractTable, "symbols"),
            .expressions = @offsetOf(ir.ContractTable, "expressions"),
            .symbol_columns = projection.referenced(Columns, ir.SymbolTable),
            .expression_columns = projection.referenced(Columns, ir.ExpressionTable),
        };
    };

    return &Definition.layout;
}
