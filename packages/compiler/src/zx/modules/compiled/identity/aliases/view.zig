const std = @import("std");
const zx = @import("zx");
const memory = zx.memory;
pub const rule = @import("generated_native_abi_aliases");
pub const Input = std.meta.Child(rule.Input);
pub const Compiled = optionalField(Input, "compiled");
pub const Modules = std.meta.Child(@FieldType(Compiled, "modules"));
pub const Declarations = optionalField(Input, "source");
const Configured = optionalField(Input, "configured");
const Output = std.meta.Child(@FieldType(Input, "output"));
const Destination = std.meta.Child(@FieldType(Output, "rows"));
const Fields = std.meta.Child(@FieldType(Destination, "fields"));
const Published = std.meta.Child(@FieldType(Destination, "published"));

pub const Rows = struct {
    names: memory.TextColumn,
    identities: memory.ReadColumn,
    view: std.meta.Child(@FieldType(Declarations, "interfaces")),
    pub fn init(self: *Rows, rows: anytype) void {
        self.names = memory.borrowTextColumn("specifier", rows);
        self.identities = memory.borrowReadColumn(?[]const u8, "identity", rows);
        self.view = .{ .names = @ptrCast(&self.names), .identities = @ptrCast(&self.identities), .count = rows.len };
    }
};

pub fn View(comptime Alias: type) type {
    return struct {
        rows: memory.RowOutput(Alias, Fields, .{ .names = &.{"name"}, .specifiers = &.{"specifier"} }),
        read: [2]memory.ReadColumn,
        growth: memory.RowGrowth,
        published: Published,
        progress: [1]u64,
        count: []u64,
        pending_text: [1]?[]const u8,
        pending: []?[]const u8,
        destination: Destination,
        output: Output,
        names: memory.TextColumn,
        requests: memory.TextColumn,
        configured: Configured,
        pub fn init(self: *@This(), configured: ?[]const Alias) void {
            self.rows.init();

            self.growth = .{ .target = &self.rows.buffer, .reads = &self.read };

            self.growth.refresh();

            inline for (@typeInfo(Fields).@"struct".field_names, 0..) |name, index| {
                @field(self.published, name) = @ptrCast(&self.read[index]);
            }

            self.progress = .{0};
            self.count = &self.progress;
            self.pending_text = .{null};
            self.pending = &self.pending_text;

            self.destination = .{
                .fields = &self.rows.view,
                .published = &self.published,
                .growth = @ptrCast(&self.growth),
                .progress = @ptrCast(&self.count),
            };

            self.output = .{ .rows = &self.destination, .pending = @ptrCast(&self.pending) };

            if (configured) |entries| {
                self.names = memory.borrowTextColumn("name", entries);
                self.requests = memory.borrowTextColumn("specifier", entries);
                self.configured = .{ .names = @ptrCast(&self.names), .requests = @ptrCast(&self.requests), .count = entries.len };
            }
        }
        pub fn release(self: *const @This(), allocator: std.mem.Allocator, own_targets: bool, own_names: bool) void {
            const rows = self.rows.rows();

            if (own_targets) {
                if (self.pending_text[0]) |pending| allocator.free(pending);

                for (rows[0..@intCast(self.progress[0])]) |row| {
                    if (own_names) allocator.free(row.name);

                    allocator.free(row.specifier);
                }
            }

            allocator.free(rows);
        }
        pub fn take(self: *const @This(), allocator: std.mem.Allocator) std.mem.Allocator.Error![]const Alias {
            var list = std.ArrayList(Alias).fromOwnedSlice(self.rows.rows());

            list.items.len = @intCast(self.progress[0]);

            return list.toOwnedSlice(allocator);
        }
    };
}

fn optionalField(comptime T: type, comptime name: []const u8) type {
    return std.meta.Child(@typeInfo(@FieldType(T, name)).optional.child);
}
