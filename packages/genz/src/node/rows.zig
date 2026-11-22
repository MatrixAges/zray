const std = @import("std");
const Columns = @import("columns.zig").Columns;

pub fn Rows(comptime Row: type) type {
    return struct {
        const Self = @This();
        const names = @typeInfo(Row).@"union".field_names;
        const Tag = std.meta.Tag(Row);
        const Header = struct { tag: Tag, offset: u32 };

        const Payloads = blk: {
            var types: [names.len]type = undefined;

            for (names, &types) |name, *target| target.* = Columns(@FieldType(Row, name));

            break :blk @Struct(.auto, null, names, &types, &@splat(.{}));
        };
        tags: std.ArrayList(Tag) = .empty,
        offsets: std.ArrayList(u32) = .empty,
        payloads: Payloads,
        pub fn init() Self {
            var result: Self = .{ .payloads = undefined };

            inline for (names) |name| @field(result.payloads, name) = .init();

            return result;
        }
        pub fn append(self: *Self, allocator: std.mem.Allocator, value: Row) std.mem.Allocator.Error!u32 {
            const header = try self.prepare(allocator, value);
            const id: u32 = @intCast(self.tags.items.len);

            self.tags.appendAssumeCapacity(header.tag);
            self.offsets.appendAssumeCapacity(header.offset);

            return id;
        }
        pub fn prepare(self: *Self, allocator: std.mem.Allocator, value: Row) std.mem.Allocator.Error!Header {
            if (self.tags.items.len >= std.math.maxInt(u32)) return error.OutOfMemory;
            try self.tags.ensureUnusedCapacity(allocator, 1);
            try self.offsets.ensureUnusedCapacity(allocator, 1);

            return switch (value) {
                inline else => |payload, selected| stored: {
                    const items = &@field(self.payloads, @tagName(selected));
                    const index: u32 = @intCast(items.count());

                    try items.reserve(allocator, 1);

                    items.append(payload);

                    break :stored .{ .tag = selected, .offset = index };
                },
            };
        }

        pub fn get(self: *const Self, id: u32) Row {
            const offset = self.offsets.items[id];

            return switch (self.tags.items[id]) {
                inline else => |tag| @unionInit(Row, @tagName(tag), @field(self.payloads, @tagName(tag)).get(offset)),
            };
        }
    };
}
