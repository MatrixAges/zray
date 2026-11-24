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
const declared_fields = .{ .names = "specifier", .identities = "identity" };
const configured_fields = .{ .names = "name", .requests = "specifier" };

pub const Rows = struct {
    columns: memory.ReadFields(declared_fields),
    view: std.meta.Child(@FieldType(Declarations, "interfaces")),
    pub fn init(self: *Rows, rows: anytype) void {
        self.columns = memory.borrowReadFields(declared_fields, rows);
        self.view = self.columns.bind(@TypeOf(self.view));
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
        configured_columns: memory.ReadFields(configured_fields),
        configured: Configured,
        pub fn init(self: *@This(), configured: ?[]const Alias) void {
            self.rows.init();

            self.growth = .{ .target = &self.rows.buffer, .reads = &self.read };

            inline for (@typeInfo(Fields).@"struct".field_names, 0..) |name, index| {
                self.growth.refreshCell(index, 0);
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
                self.configured_columns = memory.borrowReadFields(configured_fields, entries);
                self.configured = self.configured_columns.bind(Configured);
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
