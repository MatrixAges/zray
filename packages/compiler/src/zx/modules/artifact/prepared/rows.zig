const std = @import("std");
const Record = @import("../../module_record.zig");
const Binding = @import("../../function_import.zig");
const Self = @This();

function_imports: []Binding = &.{},
members: []Binding = &.{},
dependencies: []Record.Import = &.{},
imports_written: usize = 0,
members_written: usize = 0,
dependencies_written: usize = 0,
pub fn bindings(self: *Self, allocator: std.mem.Allocator, record: *const Record, entry: anytype) std.mem.Allocator.Error!void {
    const rows = if (entry.member) &self.members else &self.function_imports;
    const written = if (entry.member) &self.members_written else &self.imports_written;

    if (rows.len == 0) {
        rows.* = try allocator.alloc(Binding, if (entry.member) record.reexports.functions.len else record.function_imports.len);
    }

    const name = try allocator.dupe(u8, entry.name);

    errdefer allocator.free(name);

    const namespace = if (entry.namespace) |text| try allocator.dupe(u8, text) else null;

    rows.*[@intCast(entry.row)] = .{
        .name = name,
        .namespace = namespace,
        .id = if (entry.id) |id| @fromBackingInt(id) else null,
        .input_type = if (entry.input_type) |id| @fromBackingInt(id) else null,
        .output_type = if (entry.output_type) |id| @fromBackingInt(id) else null,
        .intrinsic = if (entry.intrinsic) |id| @fromBackingInt(id) else null,
    };

    written.* += 1;
}

pub fn dependency(self: *Self, allocator: std.mem.Allocator, source: []const Record.Import, entry: anytype) std.mem.Allocator.Error!void {
    if (self.dependencies.len == 0) self.dependencies = try allocator.alloc(Record.Import, source.len);

    const index: usize = @intCast(entry.row);
    var row = source[index];

    row.specifier = try allocator.dupe(u8, entry.specifier);

    errdefer allocator.free(row.specifier);

    row.identity = if (entry.identity) |text| try allocator.dupe(u8, text) else null;

    errdefer if (row.identity) |text| allocator.free(text);

    row.names = try copyNames(allocator, entry.names);

    errdefer releaseNames(allocator, row.names);

    row.source_names = try copyNames(allocator, entry.source_names);

    errdefer releaseNames(allocator, row.source_names);

    if (entry.path) |path| row.target.path = try allocator.dupe(u8, path);

    self.dependencies[index] = row;
    self.dependencies_written += 1;
}

pub fn release(self: *Self, allocator: std.mem.Allocator, source: []const Record.Import) void {
    releaseBindings(allocator, self.function_imports, self.imports_written);
    releaseBindings(allocator, self.members, self.members_written);

    for (self.dependencies[0..self.dependencies_written], source[0..self.dependencies_written]) |entry, original| {
        const path = if (original.target.kind == .source) entry.target.path else null;

        releaseDependency(allocator, entry.specifier, entry.identity, entry.names, entry.source_names, path);
    }

    allocator.free(self.dependencies);
}

fn releaseBindings(allocator: std.mem.Allocator, rows: []Binding, written: usize) void {
    for (rows[0..written]) |entry| {
        allocator.free(entry.name);

        if (entry.namespace) |text| allocator.free(text);
    }

    allocator.free(rows);
}

fn releaseDependency(allocator: std.mem.Allocator, specifier: []const u8, identity: ?[]const u8, names: []const []const u8, source_names: []const []const u8, path: ?[]const u8) void {
    allocator.free(specifier);

    if (identity) |text| allocator.free(text);

    releaseNames(allocator, names);
    releaseNames(allocator, source_names);

    if (path) |text| allocator.free(text);
}

fn copyNames(allocator: std.mem.Allocator, names: []const []const u8) std.mem.Allocator.Error![]const []const u8 {
    const rows = try allocator.alloc([]const u8, names.len);
    var written: usize = 0;

    errdefer allocator.free(rows);
    errdefer for (rows[0..written]) |text| allocator.free(text);

    for (names, rows) |value, *row| {
        row.* = try allocator.dupe(u8, value);
        written += 1;
    }

    return rows;
}

fn releaseNames(allocator: std.mem.Allocator, names: []const []const u8) void {
    for (names) |text| allocator.free(text);

    allocator.free(names);
}
