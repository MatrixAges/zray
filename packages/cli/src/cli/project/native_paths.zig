const std = @import("std");
const project = @import("../project.zig");
const memory = @import("zx").memory;
const Request = std.meta.Child(@import("cli_source").build_native_application.Input);
const Native = std.meta.Child(@FieldType(Request, "native"));
const Setup = std.meta.Child(@FieldType(Native, "setup"));
const Columns = std.meta.Child(@FieldType(Setup, "settings"));
const Views = std.meta.Child(@FieldType(Native, "abi_views"));
const settings_fields = .{ .names = "name", .roots = "root", .includes = "include_paths" };
const abi_fields = .{ .names = "name", .targets = "module" };

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
