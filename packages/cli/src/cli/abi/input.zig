const std = @import("std");
const compiler = @import("compiler");
const memory = @import("zx").memory;
const plan = compiler.zig.bundle_abi;
const Loaded = @import("../project.zig").Loaded;
const Settings = std.meta.Child(@FieldType(plan.Input, "settings"));
const BindingLists = std.meta.Child(@FieldType(plan.Scopes, "interfaces"));

pub const Borrowed = struct {
    modules: plan.Bindings,
    scopes: plan.Scopes,
    scope_roots: memory.TextColumn,
    interfaces: Lists,
    externals: Lists,
    settings: Settings,
    setting_names: memory.TextColumn,
    setting_roots: memory.TextColumn,
    files: memory.TextColumn,
    natives: []const *const plan.Native,
    root: []const u8,
    pub fn init(self: *Borrowed, allocator: std.mem.Allocator, modules: compiler.ir.NativeModuleTable, files: []const compiler.zig.ModuleFile, loaded: Loaded) std.mem.Allocator.Error!void {
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
        self.root = loaded.project.root_dir;
        self.natives = try borrowNatives(allocator, loaded.config.native_modules);
    }

    pub fn input(self: *const Borrowed) plan.Input {
        return .{ .modules = &self.modules, .root = self.root, .scopes = &self.scopes, .natives = self.natives, .settings = &self.settings, .file_count = self.files.count, .files = @ptrCast(&self.files) };
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

const Native = struct {
    names: memory.TextColumn,
    identities: memory.TextColumn,
    aliases: plan.AliasRows,
    value: plan.Native,
};

fn borrowNatives(allocator: std.mem.Allocator, modules: anytype) std.mem.Allocator.Error![]const *const plan.Native {
    const views = try allocator.alloc(Native, modules.len);
    const pointers = try allocator.alloc(*const plan.Native, modules.len);

    for (modules, views, pointers) |module, *target, *pointer| {
        target.value = .{ .name = module.name, .aliases = null };

        if (module.abi_aliases) |aliases| {
            target.names = memory.borrowTextColumn("name", aliases);
            target.identities = memory.borrowTextColumn("specifier", aliases);
            target.aliases = .{ .count = aliases.len, .names = @ptrCast(&target.names), .identities = @ptrCast(&target.identities) };
            target.value.aliases = &target.aliases;
        }

        pointer.* = &target.value;
    }

    return pointers;
}
