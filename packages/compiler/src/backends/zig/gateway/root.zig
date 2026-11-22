const std = @import("std");
const generating = @import("genz");
const modules = @import("../modules.zig");
const library = @import("../library.zig");
const Workflow = @import("workflow.zig");
pub const Options = Workflow.Options;
pub const Route = generating.gateway.Route;
pub const bindRoutes = @import("routes.zig").bind;

pub fn create(result: *const @import("../../../library/root.zig").Result, bundle: *library.Bundle, options: Options) !modules.Bundle {
    var frame: Workflow = .{
        .allocator = bundle.arena.allocator(),
        .options = options,
        .library = result,
        .bundle = bundle,
    };

    try frame.build();

    const generated = modules.Bundle{
        .arena = bundle.arena,
        .entry = frame.entry,
        .types = bundle.types,
        .modules = frame.files.items,
        .type_names = bundle.type_names,
        .native_modules = bundle.native_modules,
        .store_initializers = bundle.store_initializers,
    };

    bundle.* = undefined;

    return generated;
}

pub fn empty(allocator: std.mem.Allocator, options: Options) !modules.Bundle {
    var arena = std.heap.ArenaAllocator.init(allocator);

    errdefer arena.deinit();

    var frame: Workflow = .{ .allocator = arena.allocator(), .options = options };

    try frame.build();

    return .{ .arena = arena, .entry = frame.entry, .types = "", .modules = frame.files.items };
}
