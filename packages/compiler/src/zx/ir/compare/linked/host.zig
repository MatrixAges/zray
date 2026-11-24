const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const memory = zx.memory;
const projection = @import("../borrow.zig");
const referenced = @import("../referenced/host.zig");
const groups = referenced.groups;

pub fn View(comptime Functions: type) type {
    const Part = std.meta.Child(@FieldType(Functions, "prefix"));
    const Headers = std.meta.Child(@FieldType(Part, "headers"));
    const References = std.meta.Elem(@FieldType(Part, "bodies"));
    const Columns = std.meta.Child(@FieldType(Functions, "columns"));
    const Layout = std.meta.Child(@FieldType(Functions, "contract_layout"));

    const Table = struct {
        headers: Headers,
        rows: [groups.len]memory.ReferenceRows,
        references: [groups.len]References,
        view: Part,
        fn borrow(self: *@This(), table: *const ir.FunctionTable) void {
            self.headers = zx.columns.borrow(Headers, table);

            inline for (groups, 0..) |group, index| {
                self.rows[index] = memory.borrowReferenceRows(@field(table, group[1]));
                self.references[index] = @ptrCast(&self.rows[index]);
            }

            self.view = .{
                .headers = &self.headers,
                .bodies = &self.references,
                .contracts = @ptrCast(&self.rows[groups.len - 1]),
            };
        }
    };

    return struct {
        prefix: Table,
        local: Table,
        input: Functions,
        pub fn init(self: *@This(), prefix: *const ir.FunctionTable, local: *const ir.FunctionStorage) void {
            const tail = local.view();

            self.prefix.borrow(prefix);
            self.local.borrow(&tail);

            self.input = .{
                .prefix = &self.prefix.view,
                .local = &self.local.view,
                .columns = projection.groups(Columns, groups),
                .contract_layout = referenced.contractLayout(Layout),
            };
        }
    };
}
