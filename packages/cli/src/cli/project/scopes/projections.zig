const std = @import("std");
const compiler = @import("compiler");
const memory = @import("zx").memory;
const Request = std.meta.Child(@import("cli_source").native_scope_load.Input);
const Workspace = std.meta.Child(@FieldType(Request, "workspace"));
const Publication = std.meta.Child(@FieldType(Workspace, "declarations"));
const Native = std.meta.Child(@FieldType(Publication, "declarations"));
const External = std.meta.Child(@FieldType(Publication, "externals"));
const native_fields = .{ .identities = "identity", .specifiers = "specifier", .paths = "path", .modules = "module", .namespaces = "namespace" };
const legacy_fields = .{ .identities = "identity", .names = "specifier" };

pub const NativeSettings = struct { name: []const u8, root: []const u8, include_paths: []const []const u8 };

pub const Declarations = struct {
    native: memory.ReadFields(native_fields),
    legacy: memory.ReadFields(legacy_fields),
    native_views: Native,
    legacy_views: External,
    view: Publication,
    pub fn init(self: *@This(), native: []const compiler.project.NativeInterface, legacy: []const compiler.project.External) void {
        self.native = memory.borrowReadFields(native_fields, native);
        self.legacy = memory.borrowReadFields(legacy_fields, legacy);
        self.native_views = self.native.bind(Native);
        self.legacy_views = self.legacy.bind(External);
        self.view = .{ .declarations = &self.native_views, .externals = &self.legacy_views };
    }
};
