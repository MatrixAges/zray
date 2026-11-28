const std = @import("std");
const zx = @import("zx");
const syntax = zx.syntax.borrow;
const shape = @import("../shape.zig");

pub const Boundary = struct {
    left: u64,
    right: u64,
    left_start: u64 = 0,
    right_end: u64 = 0,
    adjacent: bool = false,
    same_kind: bool = false,
    same_shape: bool = false,
};

pub fn collectBody(allocator: std.mem.Allocator, source: []const u8, body: anytype) std.mem.Allocator.Error![]const Boundary {
    var collector: Collector = .{ .allocator = allocator, .source = source };

    errdefer collector.result.deinit(allocator);

    try collector.block(body);

    return collector.result.toOwnedSlice(allocator);
}

const Collector = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    result: std.ArrayList(Boundary) = .empty,
    fn block(self: *Collector, value: anytype) std.mem.Allocator.Error!void {
        for (0..value.statements.len) |index| {
            const statement = syntax.item(value.statements, index);

            if (index > 0) {
                const previous = syntax.item(value.statements, index - 1);
                const same_kind = std.meta.activeTag(previous.value) == std.meta.activeTag(statement.value);

                try self.result.append(self.allocator, .{
                    .left = previous.span.end,
                    .right = statement.span.start,
                    .left_start = previous.span.start,
                    .right_end = statement.span.end,
                    .adjacent = true,
                    .same_kind = same_kind,
                    .same_shape = same_kind and shape.sameStatement(previous, statement),
                });
            }

            if (statement.value == .switch_stmt) {
                for (0..statement.value.switch_stmt.cases.len) |case_index| try self.block(syntax.item(statement.value.switch_stmt.cases, case_index).body);
            }

            if (statement.value == .branch) {
                try self.block(statement.value.branch.yes);
                if (statement.value.branch.no) |no| try self.block(no);
            }
        }

        if (value.statements.len > 0 and self.source[value.span.start] == '{') {
            try self.result.append(self.allocator, .{ .left = value.span.start + 1, .right = syntax.item(value.statements, 0).span.start });
            try self.result.append(self.allocator, .{ .left = syntax.item(value.statements, value.statements.len - 1).span.end, .right = value.span.end - 1 });
        }
    }
};
