const std = @import("std");
const ir = @import("zx").ir;
const columns = @import("borrow.zig");
const referenced = @import("referenced/host.zig");
pub const initializer = @import("initializer.zig");

pub fn range(comptime Target: type, earlier: *const ir.FunctionTable, current: *const ir.FunctionStorage, first: usize, end: usize) Target {
    const Layout = std.meta.Child(@FieldType(Target, "layout"));
    const Native = std.meta.Child(@FieldType(Layout, "native"));
    const Bodies = std.meta.Child(@FieldType(Layout, "bodies"));
    const Header = std.meta.Child(@FieldType(Layout, "headers"));
    const Groups = std.meta.Child(@FieldType(Bodies, "columns"));
    const Offsets = std.meta.Child(@FieldType(Native, "members"));
    const Contract = std.meta.Child(@FieldType(Layout, "contract"));
    const groups = referenced.groups;

    const Static = struct {
        const offsets: struct { [groups.len]u64, [groups.len]u64 } = data: {
            var earlier_offsets: [groups.len]u64 = undefined;
            var current_offsets: [groups.len]u64 = undefined;

            for (groups, 0..) |group, index| {
                const pair = columns.offsets(Offsets, group[1]);

                earlier_offsets[index] = pair.earlier;
                current_offsets[index] = pair.current;
            }

            break :data .{ earlier_offsets, current_offsets };
        };

        const bodies: Bodies = .{
            .earlier_offsets = &offsets[0],
            .current_offsets = &offsets[1],
            .columns = columns.groups(Groups, groups),
        };
        const native: Native = .{
            .members = &columns.offsets(Offsets, "native_members"),
            .exports = &columns.offsets(Offsets, "native_exports"),
            .errors = &columns.offsets(Offsets, "native_errors"),
            .inputs = &columns.offsets(Offsets, "native_inputs"),
        };

        const layout: Layout = .{
            .headers = columns.headers(Header),
            .native = &native,
            .bodies = &bodies,
            .contract = referenced.contractLayout(Contract),
            .contract_offsets = &columns.offsets(Offsets, "contracts"),
        };
    };

    return .{
        .earlier = @ptrCast(earlier),
        .current = @ptrCast(current),
        .first = first,
        .end = end,
        .layout = &Static.layout,
    };
}
