const std = @import("std");
const zx = @import("zx");
const enabled = @import("rx_options").generated_graph;
const batch_size = 8;
const Self = @This();

first: usize = 0,
count: usize = 0,
position: usize = 0,
rows: [batch_size]u64 = undefined,
pub fn next(self: *Self, header: anytype) ?usize {
    if (comptime enabled and @hasField(@TypeOf(header), "storage")) {
        if (self.position == self.count) {
            if (self.first == header.importCount()) return null;

            self.fill(header.storage.imports);

            if (self.count == 0) return null;
        }

        const row = self.rows[self.position];

        self.position += 1;

        return @intCast(row);
    }

    while (self.first < header.importCount()) {
        const row = self.first;

        self.first += 1;

        if (header.importAt(row).kind != .type_only) return row;
    }

    return null;
}

fn fill(self: *Self, imports: anytype) void {
    const rule = @import("generated_rx_mixed_import_rows");
    const Input = std.meta.Child(rule.Input);
    const rows: []u64 = &self.rows;

    const input: Input = .{
        .imports = zx.columns.slice(@FieldType(Input, "imports"), imports),
        .first = self.first,
        .rows = @ptrCast(&rows),
        .capacity = rows.len,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const result = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;

    self.first = @intCast(result.next);
    self.count = @intCast(result.count);
    self.position = 0;
}
