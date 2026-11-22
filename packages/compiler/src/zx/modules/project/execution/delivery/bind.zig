const zx = @import("zx");
const Frame = @import("frame.zig");
const Binding = @import("../../../binding.zig");
const Native = @import("../native.zig");
const Signature = @import("../../../source_signature.zig");

pub fn reuseProjectNativeUnit(handle: *const anyopaque) bool {
    const frame = Frame.borrow(handle);
    const project = frame.walk.project;
    const native = frame.route.interface.native;
    const key = native.key();

    frame.dependency = .native;
    frame.identity = key;
    const unit = project.native_units.get(key) orelse return false;

    frame.imported = .{ .exports = unit.exports, .members = unit.members };

    return true;
}

pub fn registerProjectNativeUnit(handle: *const anyopaque) zx.Error!u32 {
    const frame = Frame.borrow(handle);
    const native = frame.route.interface.native;

    const span = switch (frame.item) {
        inline else => |item| item.span,
    };

    const id = try Native.register(frame.walk.project, native.specifier, native.identity, native.module, span);

    return @backingInt(id);
}

pub fn loadProjectNativeUnit(handle: *const anyopaque, row: u32) zx.Error!void {
    const frame = Frame.borrow(handle);

    const span = switch (frame.item) {
        inline else => |item| item.span,
    };

    const loaded = try Native.load(frame.walk.project, frame.route.interface.native, @fromBackingInt(row), span);

    frame.imported = .{ .exports = loaded.exports, .members = loaded.members };
}

pub fn rememberProjectNativeUnit(handle: *const anyopaque, row: u32) error{OutOfMemory}!void {
    const frame = Frame.borrow(handle);
    const project = frame.walk.project;
    const key = project.native_modules.at(row).key();

    try project.native_units.put(project.allocator, key, .{ .exports = frame.imported.exports, .members = frame.imported.members });
}

pub fn bindProjectLegacy(handle: *const anyopaque) zx.Error!void {
    const frame = Frame.borrow(handle);
    const project = frame.walk.project;
    const externals = frame.scope.externals(project.options.externals);
    const first = frame.route.interface.legacy;

    switch (frame.item) {
        inline else => |item| try @import("../legacy.zig").bind(project, externals, first, item, &frame.active.imports),
    }

    frame.dependency = .external;
}

pub fn prepareProjectIntrinsic(handle: *const anyopaque) void {
    const frame = Frame.borrow(handle);
    frame.imported = .{ .exports = &.{}, .members = &@import("../../../intrinsic.zig").exports };
    frame.dependency = .intrinsic;
}

pub fn loadProjectLibrary(handle: *const anyopaque) zx.Error!void {
    const frame = Frame.borrow(handle);
    const target = frame.resolved.target.compiled;

    const span = switch (frame.item) {
        inline else => |item| item.span,
    };

    const project = frame.walk.project;

    frame.imported = try project.loadCompiled(project.units[frame.active.index].path, target, span);
    frame.dependency = .{ .compiled = target };
}

pub fn selectProjectBindings(handle: *const anyopaque, signature: bool) zx.Error!void {
    const frame = Frame.borrow(handle);
    const project = frame.walk.project;
    const imported = &frame.imported;

    const symbols: Binding.Symbols = .{
        .target = if (signature) .source else switch (frame.dependency) {
            .source => .source,
            .compiled => .compiled,
            .native, .intrinsic => .native,
            .external => unreachable,
        },
        .types = project.types.view(),
        .exports = imported.exports,
        .constants = imported.constant_exports,
        .functions = members(frame).names(),
        .signatures = if (signature) imported.signatures else &.{},
    };

    const temporary = project.bindingAllocator();

    frame.bindings = switch (frame.item) {
        inline else => |item| try Binding.select(temporary, project.allocator, item, &symbols, project.reporter),
    };
}

pub fn publishProjectBindings(handle: *const anyopaque, exported: bool, callable: bool) error{OutOfMemory}!void {
    const frame = Frame.borrow(handle);
    const active = frame.active;

    try Binding.publish(
        frame.walk.project.allocator,
        frame.bindings,
        .{
            .exports = frame.imported.exports,
            .values = frame.imported.constant_exports,
            .aliases = if (exported) &active.export_aliases else &active.aliases,
            .constants = if (exported) &active.export_constants else &active.constant_imports,
        },
        if (callable) .{
            .members = members(frame),
            .imports = if (exported) &active.export_functions else &active.imports,
        } else null,
    );
}

pub fn publishProjectReexports(handle: *const anyopaque) error{OutOfMemory}!void {
    const frame = Frame.borrow(handle);
    const project = frame.walk.project;

    try Signature.publishReexports(project.allocator, project.arena.child_allocator, .{
        .signatures = frame.imported.signatures,
        .bindings = members(frame),
        .stores = project.functions.stores.items,
        .selected = frame.bindings.functions,
    }, &frame.active.signature_members);
}

fn members(frame: *const Frame) Binding.Members {
    const imported = &frame.imported;

    return .{ .default = if (imported.default_member) |*member| member else null, .named = imported.members };
}

pub fn recordProjectImport(handle: *const anyopaque) error{OutOfMemory}!void {
    const frame = Frame.borrow(handle);

    return switch (frame.item) {
        inline else => |item| frame.walk.project.rememberImport(frame.active, item, frame.dependency, frame.identity),
    };
}
