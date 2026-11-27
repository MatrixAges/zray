const std = @import("std");
const zx = @import("zx");
const memory = zx.memory;
const Alias = @import("../../../package/manifest/model.zig").AbiAlias;
const ScopeLoad = std.meta.Child(@import("cli_source").native_scope_load.Input);
const Workspace = std.meta.Child(@FieldType(ScopeLoad, "workspace"));
const Traversal = std.meta.Child(@FieldType(Workspace, "traversal"));
pub const Input = std.meta.Child(@FieldType(Traversal, "aliases"));
pub const Compiled = optionalField(Input, "compiled");
pub const Modules = std.meta.Child(@FieldType(Compiled, "modules"));
pub const Declarations = optionalField(Input, "source");
const Configured = optionalField(Input, "configured");
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

pub const Configuration = struct {
    columns: memory.ReadFields(configured_fields),
    view: Configured,
    pub fn init(self: *@This(), entries: []const Alias) void {
        self.columns = memory.borrowReadFields(configured_fields, entries);
        self.view = self.columns.bind(Configured);
    }
};

fn optionalField(comptime T: type, comptime name: []const u8) type {
    return std.meta.Child(@typeInfo(@FieldType(T, name)).optional.child);
}
