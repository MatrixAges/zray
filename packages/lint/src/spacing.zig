const std = @import("std");
const zx = @import("zx");
const syntax = zx.syntax.borrow;
const shape = @import("shape.zig");

pub const Edit = struct {
    span: zx.Span,
    replacement: []const u8,
};

pub const Boundary = struct {
    left: u64,
    right: u64,
    separate: bool,
};

pub fn collectBody(allocator: std.mem.Allocator, source: []const u8, body: anytype) std.mem.Allocator.Error![]const Boundary {
    var collector: Collector = .{ .allocator = allocator, .source = source };

    errdefer collector.result.deinit(allocator);

    try collector.block(body);

    return collector.result.toOwnedSlice(allocator);
}

pub fn format(allocator: std.mem.Allocator, source: []const u8, changes: []const Edit) std.mem.Allocator.Error![]u8 {
    var result: std.ArrayList(u8) = .empty;

    errdefer result.deinit(allocator);

    var offset: usize = 0;

    for (changes) |change| {
        try result.appendSlice(allocator, source[offset..change.span.start]);
        try result.appendSlice(allocator, change.replacement);

        offset = change.span.end;
    }

    try result.appendSlice(allocator, source[offset..]);

    return result.toOwnedSlice(allocator);
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

                if (shape.separation(self.source, previous, statement)) |separate| {
                    try self.appendBoundary(previous.span.end, statement.span.start, separate);
                }
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
            try self.appendBoundary(value.span.start + 1, syntax.item(value.statements, 0).span.start, false);
            try self.appendBoundary(syntax.item(value.statements, value.statements.len - 1).span.end, value.span.end - 1, false);
        }
    }
    fn appendBoundary(self: *Collector, left: usize, right: usize, separate: bool) std.mem.Allocator.Error!void {
        try self.result.append(self.allocator, .{
            .left = left,
            .right = right,
            .separate = separate,
        });
    }
};
