const std = @import("std");
const node = @import("../node.zig");
const Storage = @import("storage.zig");
const Stored = @import("stored.zig").Declarations;
const rows = @import("import_rows.zig");
const Spans = @import("blocks.zig").DeclarationSpans;
const generated = @import("genz_options").generated_analysis;
pub const Output = if (generated) Sequence else std.ArrayList(node.Declaration);

pub fn init(storage: *Storage, scratch: std.mem.Allocator) Output {
    return if (generated) .{ .spans = .{ .storage = storage, .scratch = scratch } } else .empty;
}

pub fn finish(output: *Output, storage: *Storage, allocator: std.mem.Allocator) std.mem.Allocator.Error!Stored {
    if (generated) return output.spans.finish(allocator);

    return storage.declarations(allocator, output.items);
}

pub const Sequence = struct {
    spans: Spans,
    pub fn deinit(self: *Sequence) void {
        self.spans.deinit();
    }
    pub fn append(self: *Sequence, allocator: std.mem.Allocator, value: node.Declaration) std.mem.Allocator.Error!void {
        const span = try self.spans.storage.declarations(allocator, &.{value});

        try self.spans.append(span);
    }
    pub fn appendColumns(self: *Sequence, allocator: std.mem.Allocator, source: anytype, comptime borrow_text: bool) rows.Error!void {
        const storage = &self.spans.storage.declaration_rows;
        const start = storage.tags.items.len;

        if (borrow_text) {
            try rows.appendBorrowingText(allocator, storage, source);
        } else {
            try rows.append(allocator, storage, source);
        }

        try self.spans.append(.{ .start = @intCast(start), .len = @intCast(source.tags.len) });
    }
};
