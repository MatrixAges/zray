const std = @import("std");
const zx = @import("zx");
const Frame = @import("frame.zig");
const Loading = @import("../../load/host.zig");
const Target = @import("../../target/host.zig");
const Route = @import("project_execution_abi").layouts.@"zig:project_host".ProjectImportRoute;

pub fn routeProjectImport(handle: *anyopaque) std.mem.Allocator.Error!Route {
    const frame = Frame.borrow(handle);
    const project = frame.walk.project;
    const active = frame.active;
    const path = project.units[active.index].path;
    const options = &project.options;
    frame.scope = active.packageScope(options.package_scopes, path);

    const scoped = frame.scope.nativeInterfaces(options.native_interfaces);
    const externals = frame.scope.externals(options.externals);

    const plan = switch (frame.item) {
        inline else => |item| try Loading.route(project.arena.child_allocator, &active.imported_names, options.internal_modules, scoped, externals, item),
    };

    const selected = switch (plan) {
        .duplicate => |name| {
            frame.duplicate = name;

            return .DuplicateBinding;
        },
        .selected => |choice| choice,
    };

    frame.route = selected;

    return switch (selected) {
        .target => |target| switch (target) {
            .Invalid => .InvalidSpecifier,
            .Intrinsic => .Intrinsic,
            .File, .Package => .Resolve,
            .Interface => unreachable,
        },
        .interface => |interface| switch (interface) {
            .native => .Native,
            .legacy => .Legacy,
            .duplicate => .DuplicateInterface,
            .conflict => .InterfaceConflict,
            .invalid_legacy => .InvalidLegacy,
            .missing_legacy => .MissingLegacy,
        },
    };
}

pub fn rejectProjectRoute(handle: *anyopaque, route: Route, message: []const u8) error{InvalidSource}!void {
    const frame = Frame.borrow(handle);
    const reporter = frame.walk.project.reporter;

    if (route == .DuplicateBinding) {
        return @errorCast(reporter.fail(.name, frame.duplicate.span, message));
    }

    const span = switch (frame.item) {
        inline else => |item| item.span,
    };

    return @errorCast(reporter.fail(if (route == .MissingLegacy) .capability else .module, span, message));
}

pub fn resolveProjectImport(handle: *anyopaque) zx.Error!bool {
    const frame = Frame.borrow(handle);
    const project = frame.walk.project;
    const path = project.units[frame.active.index].path;
    frame.path_memory = .init(&frame.path_buffer, frame.walk.paths.allocator());

    const scratch = frame.path_memory.allocator();
    const memory: Target.Memory = .{ .source = scratch, .compiled = scratch };

    frame.resolved = switch (frame.item) {
        inline else => |item| try Target.resolveIndexed(memory, path, item.path, frame.route.target, project.options, frame.scope, null, project.reporter, item.span),
    };

    frame.path_started = true;

    return frame.resolved.target == .source;
}
