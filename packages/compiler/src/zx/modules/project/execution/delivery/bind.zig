const zx = @import("zx");
const Frame = @import("frame.zig");

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

    frame.imported = try frame.walk.project.loadCompiled(target, span);
    frame.dependency = .{ .compiled = target };
}

pub fn bindProjectSignature(handle: *const anyopaque) zx.Error!void {
    const frame = Frame.borrow(handle);

    return switch (frame.item) {
        inline else => |item| frame.walk.project.bindSignature(frame.active, item, frame.imported),
    };
}

pub fn bindProjectBody(handle: *const anyopaque) zx.Error!void {
    const frame = Frame.borrow(handle);

    return switch (frame.item) {
        inline else => |item| frame.walk.project.bindBody(frame.active, item, frame.imported, frame.dependency),
    };
}

pub fn recordProjectImport(handle: *const anyopaque) error{OutOfMemory}!void {
    const frame = Frame.borrow(handle);

    return switch (frame.item) {
        inline else => |item| frame.walk.project.rememberImport(frame.active, item, frame.dependency, frame.identity),
    };
}
