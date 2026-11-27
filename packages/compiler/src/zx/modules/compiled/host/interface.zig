const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const memory = zx.memory;
const model = @import("../../compiled.zig");
const Input = @import("input.zig");
const surface = @import("../../artifact/surface.zig");
const Layout = @import("installation.zig").Layout;
const Request = std.meta.Child(@typeInfo(@FieldType(Layout, "interface")).optional.child);
const Targets = std.meta.Child(@FieldType(Request, "targets"));

pub const Interface = struct {
    exports: []const model.Export = &.{},
    initializers: []const model.StoreInitializer = &.{},
};

pub const View = struct {
    exports: memory.RowOutput(model.Export, Field("exports"), .{
        .names = &.{"name"},
        .paths = &.{"path"},
        .functions = &.{"function"},
        .types = &.{"types"},
        .members = &.{"members"},
    }),
    types: memory.RowOutput(ir.Export, Field("types"), .{ .names = &.{"name"}, .ids = &.{"type_id"} }),
    members: memory.RowOutput(@import("../../function_import.zig"), Field("members"), .{
        .names = &.{"name"},
        .namespaces = &.{"namespace"},
        .ids = &.{"id"},
        .inputs = &.{"input_type"},
        .outputs = &.{"output_type"},
        .intrinsics = &.{"intrinsic"},
    }),
    initializers: memory.RowOutput(model.StoreInitializer, Field("initializers"), .{ .identities = &.{"identity"}, .versions = &.{"schema_version"}, .functions = &.{"function"} }),
    buffers: std.meta.Child(@FieldType(Request, "buffers")),
    targets: Targets,
    request: Request,
    initializer_count: usize,
    borrowed_initializers: bool,
    initializers_written: usize,
    exports_written: usize,
    active_export: ?usize,
    types_written: usize,
    members_written: usize,
    pub fn init(self: *View, input: *const Input, instance: []const u8, first: usize, initializer_tail: ?[]model.StoreInitializer) void {
        inline for (@typeInfo(Targets).@"struct".field_names) |name| {
            const rows = &@field(self, name);

            rows.init();
            @field(self.buffers, name) = @ptrCast(&rows.buffer);
            @field(self.targets, name) = &rows.view;
        }

        if (initializer_tail) |rows| self.initializers.bind(rows);

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
            .buffers = &self.buffers,
            .targets = &self.targets,
        };
    }

    pub fn result(self: *const View) Interface {
        return .{ .exports = self.exports.rows(), .initializers = self.initializers.rows() };
    }
    pub fn commit(self: *View, allocator: std.mem.Allocator, entry: anytype) std.mem.Allocator.Error!void {
        const row: usize = @intCast(entry.row);

        switch (entry.kind) {
            .Name => {
                self.exports.rows()[row].name = try allocator.dupe(u8, entry.text);

                self.exports_written = row + 1;
                self.active_export = null;
            },
            .Header => {
                self.exports.rows()[row] = .{
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
                self.types.rows()[row] = .{
                    .name = try allocator.dupe(u8, entry.text),
                    .type_id = @fromBackingInt(entry.id.?),
                };

                self.types_written = row + 1;
            },
            .Member => {
                self.members.rows()[row] = .{
                    .name = try allocator.dupe(u8, entry.text),
                    .id = if (entry.id) |id| @fromBackingInt(id) else null,
                    .input_type = if (entry.input) |id| @fromBackingInt(id) else null,
                    .output_type = if (entry.output) |id| @fromBackingInt(id) else null,
                    .intrinsic = if (entry.intrinsic) |id| @fromBackingInt(id) else null,
                };

                self.members_written = row + 1;
            },
            .Constants => {
                self.exports.rows()[row].constants = try surface.ownConstants(allocator, entry.constants.?);
            },
            .Initializer => {
                errdefer allocator.free(entry.text);

                if (self.initializers.rows().len == 0) {
                    self.initializers.bind(try allocator.alloc(model.StoreInitializer, self.initializer_count));
                }

                self.initializers.rows()[row] = .{
                    .identity = entry.text,
                    .schema_version = entry.version.?,
                    .function = @fromBackingInt(entry.id.?),
                };

                self.initializers_written = row + 1;
            },
        }
    }
    pub fn release(self: *const View, allocator: std.mem.Allocator, selection: anytype) void {
        const published = self.exports.rows();
        const initializers = self.initializers.rows();

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

fn Field(comptime name: []const u8) type {
    return std.meta.Child(@FieldType(Targets, name));
}
