const std = @import("std");
const project = @import("../project.zig");
const memory = @import("zx").memory;
const Request = std.meta.Child(@import("cli_source").build_native_application.Input);
const Native = std.meta.Child(@FieldType(Request, "native"));
const Setup = std.meta.Child(@FieldType(Native, "setup"));
const Columns = std.meta.Child(@FieldType(Setup, "settings"));
const Views = std.meta.Child(@FieldType(Native, "abi_views"));
const Modules = std.meta.Child(@FieldType(Native, "modules"));
const settings_fields = .{ .names = "name", .roots = "root", .includes = "include_paths" };

const module_fields = .{
    .names = "name",
    .includes = "include_paths",
    .paths = "path",
    .headers = "header",
    .bundles = "bundle_files",
};

const abi_fields = .{ .names = "name", .targets = "module", .files = "path" };

pub const Paths = struct {
    fields: memory.ReadFields(settings_fields),
    columns: Columns,
    setup: Setup,
    pub fn init(self: *Paths, loaded: *const project.Loaded, owner: *const std.mem.Allocator) void {
        self.fields = memory.borrowReadFields(settings_fields, loaded.native_settings);
        self.columns = self.fields.bind(Columns);

        self.setup = .{
            .owner = @ptrCast(owner),
            .root = loaded.project.root_dir,
            .includes = loaded.config.include_paths,
            .libraries = loaded.config.library_paths,
            .settings = &self.columns,
        };
    }
};

pub const Abi = struct {
    fields: memory.ReadFields(abi_fields),
    view: Views,
    pub fn init(self: *Abi, files: anytype) void {
        self.fields = memory.borrowReadFields(abi_fields, files);
        self.view = self.fields.bind(Views);
    }
};

pub const NativeModules = struct {
    fields: memory.ReadFields(module_fields),
    view: Modules,
    pub fn init(self: *NativeModules, loaded: *const project.Loaded) void {
        self.fields = memory.borrowReadFields(module_fields, loaded.config.native_modules);
        self.view = self.fields.bind(Modules);
    }
};
