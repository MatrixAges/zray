const std = @import("std");
const compiler = @import("compiler");
const zx = @import("zx");
const memory = zx.memory;
const rule = @import("cli_source").library_output_layout;
const Export = @import("../../../package/manifest/model.zig").Export;
const Module = compiler.zig.host.library.Module;
const Input = std.meta.Child(rule.Input);
const ModuleOutput = std.meta.Child(@FieldType(Input, "generated_rows"));
const ExportOutput = std.meta.Child(@FieldType(Input, "export_rows"));
const Modules = std.meta.Child(@FieldType(Input, "generated"));

const Target = memory.RowOutput(Module, ModuleOutput, .{
    .names = &.{"name"},
    .paths = &.{"path"},
    .dependencies = &.{"dependencies"},
});

const Exports = memory.RowOutput(Export, ExportOutput, .{
    .paths = &.{"path"},
    .modules = &.{"module"},
    .sources = &.{"source"},
});

pub const Plan = struct {
    name: []const u8,
    version: []const u8,
    exports: []const Export,
    generated: []const Module,
    public: []const Module,
};

pub fn create(allocator: std.mem.Allocator, config: @import("../../project.zig").Config, library: *const compiler.library.Result, bundle: *const compiler.zig.LibraryBundle) !Plan {
    const generated = try allocator.alloc(Module, bundle.modules.len);
    const public = try allocator.alloc(Module, bundle.public_modules.len);
    const exports = try allocator.alloc(Export, library.exports.len);
    var generated_target: Target = undefined;
    var public_target: Target = undefined;
    var export_target: Exports = undefined;

    generated_target.init();
    generated_target.bind(generated);
    public_target.init();
    public_target.bind(public);
    export_target.init();
    export_target.bind(exports);

    const exported = memory.borrowTextColumn("name", library.exports);
    const generated_input = Sources.init(&.{"name"}, &.{"imports"}, bundle.modules);
    const public_input = Sources.init(&.{ "file", "name" }, &.{ "file", "imports" }, bundle.public_modules);

    const plan = try zx.columns.invoke(rule.executeValue, allocator, &Input{
        .package = &.{ .name = config.name, .version = config.version },
        .legacy = config.exports.len == 0,
        .exports = &.{ .names = @ptrCast(&exported), .count = library.exports.len },
        .export_rows = &export_target.view,
        .generated = &generated_input.input(),
        .generated_rows = &generated_target.view,
        .public = &public_input.input(),
        .public_rows = &public_target.view,
    });

    if (!plan.valid) return error.ConflictingModuleName;

    return .{
        .name = plan.package.name,
        .version = plan.package.version,
        .exports = exports,
        .generated = generated,
        .public = public,
    };
}

const Sources = struct {
    names: memory.TextColumn,
    basenames: memory.TextColumn,
    dependencies: memory.ReadColumn,
    fn init(comptime basename: []const []const u8, comptime dependencies: []const []const u8, rows: anytype) Sources {
        return .{
            .names = memory.borrowTextColumn("name", rows),
            .basenames = memory.borrowNestedColumn([]const u8, basename, rows),
            .dependencies = memory.borrowNestedColumn([]const []const u8, dependencies, rows),
        };
    }
    fn input(self: *const Sources) Modules {
        return .{
            .names = @ptrCast(&self.names),
            .basenames = @ptrCast(&self.basenames),
            .dependencies = @ptrCast(&self.dependencies),
            .count = self.names.count,
        };
    }
};
