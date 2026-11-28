const std = @import("std");
const compiler = @import("compiler");
const memory = @import("zx").memory;
const Request = std.meta.Child(@import("cli_source").native_scope_load.Input);
const Workspace = std.meta.Child(@FieldType(Request, "workspace"));
const Publication = std.meta.Child(@FieldType(Workspace, "declarations"));
const Native = std.meta.Child(@FieldType(Publication, "declarations"));
const native_fields = .{ .paths = "path", .namespaces = "namespace" };

pub const NativeSettings = struct { name: []const u8, root: []const u8, include_paths: []const []const u8 };

pub const Declarations = struct {
    native: memory.ReadFields(native_fields),
    native_views: Native,
    view: Publication,
    pub fn init(self: *@This(), native: []const compiler.project.NativeInterface) void {
        self.native = memory.borrowReadFields(native_fields, native);
        self.native_views = self.native.bind(Native);
        self.view = .{ .declarations = &self.native_views };
    }
};
