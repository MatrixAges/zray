const std = @import("std");
const compiler = @import("compiler");
const memory = @import("zx").memory;
const model = @import("../../../package/manifest/model.zig");
const Request = std.meta.Child(@typeInfo(@import("cli_source").native_scope_load.Input).optional.child);
const Workspace = std.meta.Child(@FieldType(Request, "workspace"));
const Publication = std.meta.Child(@FieldType(Workspace, "declarations"));
const Native = std.meta.Child(@FieldType(Publication, "declarations"));
const External = std.meta.Child(@FieldType(Publication, "externals"));
const Setting = std.meta.Child(@FieldType(Workspace, "settings"));
const declaration_fields = .{ .specifiers = "specifier", .paths = "path", .modules = "module", .namespaces = "namespace" };
const native_fields = .{ .identities = "identity", .specifiers = "specifier", .paths = "path", .modules = "module", .namespaces = "namespace" };
const legacy_fields = .{ .identities = "identity", .names = "specifier" };
const external_fields = .{ .identities = "identity", .specifiers = "specifier" };
const setting_fields = .{ .names = "name", .roots = "root", .includes = "include_paths" };

pub const NativeSettings = struct { name: []const u8, root: []const u8, include_paths: []const []const u8 };

pub const Declarations = struct {
    native: memory.ReadFields(native_fields),
    native_target: @TypeOf(memory.borrowWriteFields(declaration_fields, @as([]model.NativeInterface, &.{}))),
    legacy: memory.ReadFields(legacy_fields),
    external_target: @TypeOf(memory.borrowWriteFields(external_fields, @as([]compiler.project.External, &.{}))),
    native_views: std.meta.Child(@FieldType(Native, "rows")),
    native_results: std.meta.Child(@FieldType(Native, "output")),
    legacy_views: std.meta.Child(@FieldType(External, "rows")),
    external_results: std.meta.Child(@FieldType(External, "output")),
    declarations: Native,
    externals: External,
    view: Publication,
    pub fn init(self: *@This(), native: []const compiler.project.NativeInterface, legacy: []const compiler.project.External, exported: []model.NativeInterface, externals: []compiler.project.External) void {
        self.native = memory.borrowReadFields(native_fields, native);
        self.native_target = memory.borrowWriteFields(declaration_fields, exported);
        self.legacy = memory.borrowReadFields(legacy_fields, legacy);
        self.external_target = memory.borrowWriteFields(external_fields, externals);
        self.native_views = self.native.bind(@TypeOf(self.native_views));
        self.native_results = self.native_target.bind(@TypeOf(self.native_results));
        self.legacy_views = self.legacy.bind(@TypeOf(self.legacy_views));
        self.external_results = self.external_target.bind(@TypeOf(self.external_results));
        self.declarations = .{ .rows = &self.native_views, .output = &self.native_results };
        self.externals = .{ .rows = &self.legacy_views, .output = &self.external_results };
        self.view = .{ .declarations = &self.declarations, .externals = &self.externals };
    }
};

pub const Settings = struct {
    names: memory.TextColumn,
    outputs: @TypeOf(memory.borrowWriteFields(setting_fields, @as([]NativeSettings, &.{}))),
    target: std.meta.Child(@FieldType(Setting, "output")),
    view: Setting,
    pub fn init(self: *@This(), root: []const u8, includes: []const []const u8, modules: []const model.NativeModule, output: []NativeSettings) void {
        self.names = memory.borrowTextColumn("name", modules);
        self.outputs = memory.borrowWriteFields(setting_fields, output);
        self.target = self.outputs.bind(@TypeOf(self.target));
        self.view = .{ .names = @ptrCast(&self.names), .root = root, .includes = includes, .count = modules.len, .output = &self.target };
    }
};
