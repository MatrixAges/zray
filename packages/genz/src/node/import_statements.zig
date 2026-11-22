const std = @import("std");
const rows = @import("import_rows.zig");
const Sequence = @import("blocks.zig").Sequence;

pub const Error = rows.Error;

pub fn append(allocator: std.mem.Allocator, target: *Sequence, source: anytype) Error!void {
    return appendRows(allocator, target, source, false, false);
}

/// Text must outlive the target list and every AST block subsequently built from it.
pub fn appendBorrowingText(allocator: std.mem.Allocator, target: *Sequence, source: anytype) Error!void {
    return appendRows(allocator, target, source, true, false);
}

pub fn appendSelected(allocator: std.mem.Allocator, target: *Sequence, source: anytype) Error!void {
    return appendRows(allocator, target, source, false, true);
}

/// Selected rows may share payload columns; all text must outlive the target.
pub fn appendSelectedBorrowingText(allocator: std.mem.Allocator, target: *Sequence, source: anytype) Error!void {
    return appendRows(allocator, target, source, true, true);
}

fn appendRows(allocator: std.mem.Allocator, target: *Sequence, source: anytype, comptime borrow_text: bool, comptime selected_rows: bool) Error!void {
    if (source.tags.len == 0) return;

    const table = &target.storage.statements;
    const first: u32 = @intCast(table.tags.items.len);
    const importer = if (selected_rows) @import("import_selected.zig") else rows;

    if (borrow_text) {
        try importer.appendBorrowingText(allocator, table, source);
    } else {
        try importer.append(allocator, table, source);
    }

    return target.append(.{ .start = first, .len = @intCast(source.tags.len) });
}
