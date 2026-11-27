const std = @import("std");
const compiler = @import("compiler");
const zx = @import("zx");
const memory = zx.memory;
const rule = @import("cli_source").library_output_layout;
const Export = @import("../../../package/manifest/model.zig").Export;
const Module = compiler.zig.host.library.Module;
const Input = std.meta.Child(rule.Input);
const Modules = std.meta.Child(@FieldType(Input, "generated"));

pub const Plan = struct {
    name: []const u8,
    version: []const u8,
    exports: []const Export,
    generated: []const Module,
    public: []const Module,
};

pub fn create(allocator: std.mem.Allocator, config: @import("../../project.zig").Config, library: *const compiler.library.Result, bundle: *const compiler.zig.LibraryBundle) !Plan {
    const exported = memory.borrowTextColumn("name", library.exports);
    const generated_input = Sources.init(&.{"name"}, &.{"imports"}, bundle.modules);
    const public_input = Sources.init(&.{ "file", "name" }, &.{ "file", "imports" }, bundle.public_modules);

    const plan = try zx.columns.invoke(rule.executeValue, allocator, &Input{
        .package = &.{ .name = config.name, .version = config.version },
        .legacy = config.exports.len == 0,
        .exports = &.{ .names = @ptrCast(&exported), .count = library.exports.len },
        .generated = &generated_input.input(),
        .public = &public_input.input(),
    });

    if (!plan.valid) return error.ConflictingModuleName;

    const generated = try allocator.alloc(Module, plan.generated.len);
    const public = try allocator.alloc(Module, plan.public.len);
    const exports = try allocator.alloc(Export, plan.exports.len);

    for (plan.exports, exports) |item, *slot| {
        slot.* = .{ .path = item.path, .module = item.module, .source = item.source };
    }

    for (plan.generated, generated) |item, *slot| {
        slot.* = .{ .name = item.name, .path = item.path, .dependencies = item.dependencies };
    }

    for (plan.public, public) |item, *slot| {
        slot.* = .{ .name = item.name, .path = item.path, .dependencies = item.dependencies };
    }

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
