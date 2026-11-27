const std = @import("std");
const rx = @import("rx");
const Flow = @import("../../flow.zig");
const Loader = @import("../../prepare.zig").Loader;

pub const Cursors = [5]u32;

pub fn apply(loader: *Loader, cursors: *Cursors, header: anytype, implicit_header: anytype, payload: anytype) std.mem.Allocator.Error!void {
    const plan = &loader.plan;

    storeHeader(plan, cursors, header);

    if (implicit_header) |row| storeHeader(plan, cursors, row);

    if (payload.result) |row| {
        plan.results.items[row.row] = borrow(rx.ast.Attribute, row.attribute).*;
    }

    if (payload.task) |row| {
        plan.tasks.items[row.row] = .{
            .id = row.id,
            .node = borrow(rx.ast.Node, row.node),
            .output = if (row.output) |attribute| borrow(rx.ast.Attribute, attribute) else null,
            .body = unit(row),
        };
    }

    if (payload.group) |row| plan.groups.items[row.row] = unit(row);

    if (payload.selection) |row| {
        const source = row.cases;
        const cases = try loader.allocator.alloc(Flow.Case, source.kinds.len);

        for (cases, source.kinds, source.sources, source.firsts, source.counts) |*target, kind, attribute, first, count| {
            target.* = .{
                .label = .{
                    .kind = @fromBackingInt(kind),
                    .source = if (attribute.len != 0) borrow(rx.ast.Attribute, attribute) else null,
                },
                .body = .{ .first = first, .count = count },
            };
        }

        plan.selections.items[row.row] = .{ .subject = borrow(rx.ast.Attribute, row.subject), .cases = cases };
    }
}

fn storeHeader(plan: *Flow.Builder, cursors: *Cursors, row: anytype) void {
    plan.rows.set(row.position, .{ .kind = @fromBackingInt(@intCast(row.code)), .item = row.item });
    cursors[@intCast(row.lane)] = row.next;
}

fn unit(row: anytype) Flow.Unit {
    return .{ .first = row.first, .count = row.count };
}

fn borrow(comptime Value: type, bytes: []const u8) *const Value {
    std.debug.assert(bytes.len == @sizeOf(Value));

    return @ptrCast(@alignCast(bytes.ptr));
}
