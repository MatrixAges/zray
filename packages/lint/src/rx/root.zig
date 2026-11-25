const std = @import("std");
const dsl = @import("dsl");
const spacing = @import("../spacing.zig");
const rule = @import("lint_rx");
pub const structure = @import("layout.zig").format;
pub const structureView = @import("layout.zig").formatView;
pub const NodeView = @import("node_view.zig");

pub fn format(allocator: std.mem.Allocator, source: []const u8, node: dsl.ast.Node) std.mem.Allocator.Error![]u8 {
    return formatView(allocator, source, NodeView{ .node = node });
}

pub fn formatView(allocator: std.mem.Allocator, source: []const u8, node: anytype) std.mem.Allocator.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const temporary = arena.allocator();
    const planned = try rule.run(temporary, 0, source, 0, node);

    return applyEdits(allocator, temporary, source, planned, true);
}

pub fn applyEdits(allocator: std.mem.Allocator, temporary: std.mem.Allocator, source: []const u8, planned: []const rule.Edit, sort_edits: bool) std.mem.Allocator.Error![]u8 {
    const edits = try temporary.alloc(spacing.Edit, planned.len);

    for (planned, edits) |item, *slot| {
        const replacement = switch (item.kind) {
            1 => if (item.crlf) (if (item.separate) "\r\n\r\n" else "\r\n") else (if (item.separate) "\n\n" else "\n"),
            else => block: {
                const prefix: []const u8 = if (item.kind == 2) (if (item.crlf) "\r\n" else "\n") else "";
                const text = try temporary.alloc(u8, prefix.len + item.count);

                if (prefix.len > 0) @memcpy(text[0..prefix.len], prefix);

                @memset(text[prefix.len..], ' ');

                break :block text;
            },
        };

        slot.* = .{ .span = .{ .start = item.start, .end = item.end }, .replacement = replacement };
    }

    if (sort_edits) {
        std.mem.sort(spacing.Edit, edits, {}, struct {
            fn lessThan(_: void, left: spacing.Edit, right: spacing.Edit) bool {
                return left.span.start < right.span.start;
            }
        }.lessThan);
    }

    return spacing.format(allocator, source, edits);
}
