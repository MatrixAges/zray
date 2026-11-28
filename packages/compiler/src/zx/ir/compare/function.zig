const std = @import("std");
const ir = @import("zx").ir;
const columns = @import("borrow.zig");
const referenced = @import("referenced/host.zig");
pub const initializer = @import("initializer.zig");

pub fn range(comptime Target: type, earlier: *const ir.FunctionTable, current: *const ir.FunctionStorage, first: usize, end: usize) Target {
    const Layout = std.meta.Child(@FieldType(Target, "layout"));
    const Bodies = std.meta.Child(@FieldType(Layout, "bodies"));
    const Header = std.meta.Child(@FieldType(Layout, "headers"));
    const Groups = std.meta.Child(@FieldType(Bodies, "columns"));
    const Offsets = std.meta.Child(@FieldType(Layout, "contract_offsets"));
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
        const layout: Layout = .{
            .headers = columns.headers(Header),
            .bodies = &bodies,
            .contract = referenced.contractLayout(Contract),
            .contract_offsets = &columns.offsets(Offsets, "contracts"),
        };
    };

    return .{
        .earlier = @ptrCast(earlier),
        .current = @ptrCast(current),
        .earlier_files = earlier.files,
        .current_files = current.files.items,
        .earlier_native_modules = earlier.native_modules,
        .current_native_modules = current.native_modules.items,
        .earlier_roots = earlier.roots,
        .current_roots = current.roots.items,
        .earlier_members = earlier.native_members,
        .current_members = current.native_members.items,
        .earlier_exports = earlier.native_exports,
        .current_exports = current.native_exports.items,
        .earlier_errors = earlier.native_errors,
        .current_errors = current.native_errors.items,
        .earlier_inputs = earlier.native_inputs,
        .current_inputs = current.native_inputs.items,
        .first = first,
        .end = end,
        .layout = &Static.layout,
    };
}
