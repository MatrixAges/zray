const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const model = @import("../../compiled.zig");
const Input = @import("input.zig");
const surface = @import("../../artifact/surface.zig");
const Layout = @import("installation.zig").Layout;
const Request = std.meta.Child(@typeInfo(@FieldType(Layout, "interface")).optional.child);

pub const Interface = struct {
    exports: []const model.Export = &.{},
    initializers: []const model.StoreInitializer = &.{},
};

pub const View = struct {
    exports: []model.Export,
    initializers: []model.StoreInitializer,
    types: []ir.Export,
    members: []@import("../../function_import.zig"),
    request: Request,
    initializer_count: usize,
    borrowed_initializers: bool,
    initializers_written: usize,
    exports_written: usize,
    active_export: ?usize,
    types_written: usize,
    members_written: usize,
    pub fn init(self: *View, input: *const Input, instance: []const u8, first: usize, initializer_tail: ?[]model.StoreInitializer) void {
        self.exports = &.{};
        self.initializers = initializer_tail orelse &.{};
        self.types = &.{};
        self.members = &.{};
        self.borrowed_initializers = initializer_tail != null;
        self.initializer_count = @intCast(input.graph.initializers.count);
        self.initializers_written = 0;
        self.exports_written = 0;
        self.active_export = null;
        self.types_written = 0;
        self.members_written = 0;

        self.request = .{
            .exports = zx.columns.pointer(@FieldType(Request, "exports"), &input.graph.exports.input),
            .initializers = zx.columns.pointer(@FieldType(Request, "initializers"), &input.graph.initializers),
            .first = first,
            .instance = instance,
        };
    }

    pub fn result(self: *const View) Interface {
        return .{ .exports = self.exports, .initializers = self.initializers };
    }
    pub fn commit(self: *View, allocator: std.mem.Allocator, entry: anytype) std.mem.Allocator.Error!void {
        const row: usize = @intCast(entry.row);

        switch (entry.kind) {
            .AllocateExports => self.exports = try allocator.alloc(model.Export, @intCast(entry.count.?)),
            .AllocateTypes => {
                self.types = try allocator.alloc(ir.Export, @intCast(entry.count.?));
                self.exports[row].types = self.types;
            },
            .AllocateMembers => {
                self.members = try allocator.alloc(@import("../../function_import.zig"), @intCast(entry.count.?));
                self.exports[row].members = self.members;
            },
            .Alias => self.exports[row] = self.exports[@intCast(entry.source.?)],
            .Name => {
                self.exports[row].name = try allocator.dupe(u8, entry.text);
                self.exports_written = row + 1;
                self.active_export = null;
            },
            .Header => {
                self.exports[row] = .{
                    .name = &.{},
                    .path = entry.text,
                    .function = if (entry.id) |id| @fromBackingInt(id) else null,
                    .types = &.{},
                };

                self.active_export = row;
                self.types_written = 0;
                self.members_written = 0;
            },
            .Type => {
                self.types[row] = .{
                    .name = try allocator.dupe(u8, entry.text),
                    .type_id = @fromBackingInt(entry.id.?),
                };

                self.types_written = row + 1;
            },
            .Member => {
                self.members[row] = .{
                    .name = try allocator.dupe(u8, entry.text),
                    .id = if (entry.id) |id| @fromBackingInt(id) else null,
                    .input_type = if (entry.input) |id| @fromBackingInt(id) else null,
                    .output_type = if (entry.output) |id| @fromBackingInt(id) else null,
                    .intrinsic = if (entry.intrinsic) |id| @fromBackingInt(id) else null,
                };

                self.members_written = row + 1;
            },
            .Constants => {
                self.exports[row].constants = try surface.ownConstants(allocator, entry.constants.?);
            },
            .Initializer => {
                errdefer allocator.free(entry.text);

                if (self.initializers.len == 0) {
                    self.initializers = try allocator.alloc(model.StoreInitializer, self.initializer_count);
                }

                self.initializers[row] = .{
                    .identity = entry.text,
                    .schema_version = entry.version.?,
                    .function = @fromBackingInt(entry.id.?),
                };

                self.initializers_written = row + 1;
            },
        }
    }
    pub fn release(self: *const View, allocator: std.mem.Allocator, selection: anytype) void {
        const published = self.exports;
        const initializers = self.initializers;

        for (published[0..self.exports_written], 0..) |row, index| {
            allocator.free(row.name);

            if (selection) |selected| {
                if (selected.first[@intCast(selected.aliases[index])] != index) continue;
            }

            releaseExport(allocator, row, row.types.len, row.members.len, row.constants.len);
        }

        if (self.active_export) |index| {
            releaseExport(allocator, published[index], self.types_written, self.members_written, published[index].constants.len);
        }

        allocator.free(published);

        for (initializers[0..self.initializers_written]) |row| allocator.free(row.identity);
        if (!self.borrowed_initializers) allocator.free(initializers);
    }
};

fn releaseExport(allocator: std.mem.Allocator, row: model.Export, types: usize, members: usize, constants: usize) void {
    allocator.free(row.path);

    for (row.types[0..types]) |value| allocator.free(value.name);
    for (row.members[0..members]) |value| allocator.free(value.name);

    for (row.constants[0..constants]) |value| {
        allocator.free(value.name);

        if (value.value == .string) allocator.free(value.value.string);
    }

    allocator.free(row.types);
    allocator.free(row.members);
    allocator.free(row.constants);
}
