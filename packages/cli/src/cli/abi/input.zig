const compiler = @import("compiler");
const memory = @import("zx").memory;
const std = @import("std");
const Request = std.meta.Child(@import("cli_source").render_bundle_abi.Input);
pub const Input = std.meta.Child(@FieldType(Request, "plan"));
const Bindings = std.meta.Child(@FieldType(Input, "modules"));
const Scopes = std.meta.Child(@FieldType(Input, "scopes"));
const Natives = std.meta.Child(@FieldType(Input, "natives"));
const Loaded = @import("../project.zig").Loaded;
const Settings = std.meta.Child(@FieldType(Input, "settings"));
const BindingLists = std.meta.Child(@FieldType(Scopes, "interfaces"));

pub const Borrowed = struct {
    modules: Bindings,
    scopes: Scopes,
    scope_roots: memory.TextColumn,
    interfaces: Lists,
    externals: Lists,
    settings: Settings,
    setting_names: memory.TextColumn,
    setting_roots: memory.TextColumn,
    files: memory.TextColumn,
    natives: Natives,
    native_names: memory.TextColumn,
    alias_names: memory.ListColumn,
    alias_identities: memory.ListColumn,
    pub fn init(self: *Borrowed, modules: compiler.ir.NativeModuleTable, files: []const compiler.zig.ModuleFile, loaded: *const Loaded) Input {
        const scopes = loaded.project.package_scopes;
        self.modules = .{ .specifiers = modules.specifiers, .identities = modules.identities };
        self.scope_roots = memory.borrowTextColumn("root", scopes);

        self.interfaces.init("native_interfaces", scopes);
        self.externals.init("externals", scopes);
        self.scopes = .{ .count = scopes.len, .roots = @ptrCast(&self.scope_roots), .interfaces = &self.interfaces.view, .externals = &self.externals.view };
        self.setting_names = memory.borrowTextColumn("name", loaded.native_settings);
        self.setting_roots = memory.borrowTextColumn("root", loaded.native_settings);
        self.settings = .{ .count = loaded.native_settings.len, .names = @ptrCast(&self.setting_names), .roots = @ptrCast(&self.setting_roots) };
        self.files = memory.borrowTextColumn("name", files);

        const natives = loaded.config.native_modules;

        self.native_names = memory.borrowTextColumn("name", natives);
        self.alias_names = memory.borrowOptionalListColumn("abi_aliases", "name", natives);
        self.alias_identities = memory.borrowOptionalListColumn("abi_aliases", "specifier", natives);

        self.natives = .{
            .count = natives.len,
            .names = @ptrCast(&self.native_names),
            .alias_names = @ptrCast(&self.alias_names),
            .alias_identities = @ptrCast(&self.alias_identities),
        };

        return .{ .modules = &self.modules, .root = loaded.project.root_dir, .scopes = &self.scopes, .natives = &self.natives, .settings = &self.settings, .file_count = self.files.count, .files = @ptrCast(&self.files) };
    }
};

const Lists = struct {
    specifiers: memory.ListColumn,
    identities: memory.ListColumn,
    view: BindingLists,
    fn init(self: *Lists, comptime field: []const u8, scopes: []const compiler.project.PackageScope) void {
        self.specifiers = memory.borrowListColumn([]const u8, field, "specifier", scopes);
        self.identities = memory.borrowListColumn(?[]const u8, field, "identity", scopes);
        self.view = .{ .specifiers = @ptrCast(&self.specifiers), .identities = @ptrCast(&self.identities) };
    }
};
