const std = @import("std");
const Columns = @import("columns.zig").Columns;
const schema = @import("schema.zig");
const view = @import("view.zig");

pub fn Rows(comptime Row: type, comptime Layout: type) type {
    return struct {
        const Self = @This();
        const NativeTag = std.meta.Tag(Row);
        const Tag = if (Layout == void) NativeTag else schema.element(Layout, "tags");
        const names = if (Layout == void) @typeInfo(Row).@"union".field_names else &schema.payloadNames(NativeTag, Tag);
        const Header = struct { tag: Tag, offset: u32 };

        const Payloads = blk: {
            var types: [names.len]type = undefined;

            for (names, &types) |name, *target| target.* = Columns(@FieldType(Row, name), Layout, name);

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
                    const name = @tagName(selected);
                    const tag = if (Layout == void) selected else @field(Tag, view.pascal(name));
                    const items = &@field(self.payloads, name);
                    const index: u32 = @intCast(items.count());

                    try items.reserve(allocator, 1);

                    items.append(payload);

                    break :stored .{ .tag = tag, .offset = index };
                },
            };
        }

        pub fn get(self: *const Self, id: u32) Row {
            const offset = self.offsets.items[id];

            return switch (self.tags.items[id]) {
                inline else => |tag| row: {
                    const name = names[@backingInt(tag)];

                    break :row @unionInit(Row, name, @field(self.payloads, name).get(offset));
                },
            };
        }
    };
}
