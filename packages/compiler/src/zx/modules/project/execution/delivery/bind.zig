const zx = @import("zx");
const Frame = @import("frame.zig");
const Binding = @import("../../../binding.zig");
const Signature = @import("../../../source_signature.zig");

pub fn bindProjectNative(handle: *const anyopaque) zx.Error!void {
    const frame = Frame.borrow(handle);
    const native = frame.route.interface.native;

    switch (frame.item) {
        inline else => |item| try frame.walk.project.importNative(frame.active, native.*, item),
    }

    frame.dependency = .native;
    frame.identity = native.key();
}

pub fn bindProjectLegacy(handle: *const anyopaque) zx.Error!void {
    const frame = Frame.borrow(handle);
    const project = frame.walk.project;
    const externals = frame.scope.externals(project.options.externals);
    const first = frame.route.interface.legacy;

    switch (frame.item) {
        inline else => |item| try project.importExternal(externals, first, item, &frame.active.imports),
    }

    frame.dependency = .external;
}

pub fn bindProjectIntrinsic(handle: *const anyopaque) zx.Error!void {
    const frame = Frame.borrow(handle);

    switch (frame.item) {
        inline else => |item| try frame.walk.project.importIntrinsic(frame.active, item),
    }

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
        .target = if (signature or frame.dependency == .source) .source else .compiled,
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
