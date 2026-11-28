const zx = @import("zx");
const Frame = @import("frame.zig");
const Binding = @import("../../../binding.zig");
const Native = @import("../native.zig");
const ModuleRecord = @import("../../../module_record.zig");
const Project = @import("../../../project.zig").Project;
const Imported = @import("../../../project.zig").Imported;
const Signature = @import("../../../source_signature.zig").Member;

pub fn reuseNative(frame: *Frame) bool {
    const project = frame.walk.project;
    const native = frame.route.interface.native;
    const key = native.key();
    const unit = project.native_units.get(key) orelse return false;

    frame.imported = .{ .exports = unit.exports, .members = unit.members };

    return true;
}

pub fn registerNative(frame: *Frame) zx.Error!u32 {
    const native = frame.route.interface.native;

    const span = switch (frame.item) {
        inline else => |item| item.span,
    };

    const id = try Native.register(frame.walk.project, native.specifier, native.identity, native.module, span);

    return @backingInt(id);
}

pub fn loadNative(frame: *Frame, row: u32) zx.Error!void {
    const span = switch (frame.item) {
        inline else => |item| item.span,
    };

    const loaded = try Native.load(frame.walk.project, frame.route.interface.native, @fromBackingInt(row), span);

    frame.imported = .{ .exports = loaded.exports, .members = loaded.members };
}

pub fn rememberNative(frame: *Frame, row: u32) error{OutOfMemory}!void {
    const project = frame.walk.project;
    const key = project.native_modules.at(row).key();

    try project.native_units.put(project.allocator, key, .{ .exports = frame.imported.exports, .members = frame.imported.members });
}

pub fn bindLegacy(frame: *Frame) zx.Error!void {
    const project = frame.walk.project;
    const externals = frame.scope.externals(project.options.externals);
    const first = frame.route.interface.legacy;

    switch (frame.item) {
        inline else => |item| try @import("../legacy.zig").bind(project, externals, first, item, &frame.active.imports),
    }
}

pub fn loadLibrary(frame: *Frame) zx.Error!void {
    const target = frame.resolved.target.compiled;

    const span = switch (frame.item) {
        inline else => |item| item.span,
    };

    const project = frame.walk.project;

    frame.imported = try project.loadCompiled(project.units[frame.active.index].path, target, span);
}

pub fn bind(frame: *Frame, target: anytype, signature: bool, exported: bool) zx.Error!void {
    const project = frame.walk.project;
    const active = frame.active;
    var deferred: [1]Signature = undefined;

    const imported: Imported = switch (target.kind) {
        .Source => Project.importedSource(frame.sourceUnit(target.row.?), frame.walk.phase),
        .Deferred => result: {
            const path = try project.allocator.dupe(u8, frame.resolved.target.source);

            deferred[0] = .{ .name = "", .kind = .deferred, .source = path };

            break :result .{ .exports = &.{}, .signatures = &deferred };
        },
        .Compiled, .Native => frame.imported,
        .Intrinsic => .{ .exports = &.{}, .members = &@import("../../../intrinsic.zig").exports },
        .External => unreachable,
    };

    const functions: Binding.Members = .{
        .default = if (imported.default_member) |*member| member else null,
        .named = imported.members,
    };

    const symbols: Binding.Symbols = .{
        .target = if (signature) .source else switch (target.kind) {
            .Source => .source,
            .Compiled => .compiled,
            .Native, .Intrinsic => .native,
            .Deferred, .External => unreachable,
        },
        .types = project.types.view(),
        .exports = imported.exports,
        .constants = imported.constant_exports,
        .functions = functions.names(),
        .signatures = if (signature) imported.signatures else &.{},
    };

    const temporary = project.bindingAllocator();

    const lists: Binding.Lists = .{
        .types = .{
            .exports = imported.exports,
            .values = imported.constant_exports,
            .aliases = if (exported) &active.export_aliases else &active.aliases,
            .constants = if (exported) &active.export_constants else &active.constant_imports,
        },
        .functions = if (signature) null else .{
            .members = functions,
            .imports = if (exported) &active.export_functions else &active.imports,
        },
        .reexports = if (signature and exported) .{
            .signatures = imported.signatures,
            .bindings = functions,
            .stores = project.functions.stores.items,
            .rows = &active.signature_members,
            .backing = project.arena.child_allocator,
        } else null,
    };

    return switch (frame.item) {
        inline else => |item| Binding.deliver(project.allocator, temporary, item, &symbols, project.reporter, lists),
    };
}

pub fn record(frame: *Frame, target: anytype) error{OutOfMemory}!void {
    const dependency: ModuleRecord.Target.Wire = switch (target.kind) {
        .Source => .{ .source = frame.sourceUnit(target.row.?).path },
        .Compiled => .{ .compiled = frame.resolved.target.compiled },
        .Native => .native,
        .External => .external,
        .Intrinsic => .intrinsic,
        .Deferred => unreachable,
    };

    const identity = if (target.kind == .Native) frame.route.interface.native.key() else null;

    return switch (frame.item) {
        inline else => |item| frame.walk.project.rememberImport(frame.active, item, dependency, identity),
    };
}
