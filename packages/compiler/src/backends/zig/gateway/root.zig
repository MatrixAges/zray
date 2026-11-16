const std = @import("std");
const generating = @import("genz");
const modules = @import("../modules.zig");
const library = @import("../library.zig");
const storage_module_count = 2;
pub const Options = struct { routes: []const generating.gateway.Route, listen: []const u8, max_header_bytes: u32, max_body_bytes: u32 };
pub const Route = generating.gateway.Route;
pub const bindRoutes = @import("routes.zig").bind;

pub fn create(result: *const @import("../../../library/root.zig").Result, bundle: *library.Bundle, options: Options) !modules.Bundle {
    const allocator = bundle.arena.allocator();
    const mapped = try @import("state.zig").create(allocator, result, bundle.*);
    const count = std.math.add(usize, bundle.modules.len, bundle.public_modules.len) catch return error.OutOfMemory;
    const capacity = std.math.add(usize, count, storage_module_count) catch return error.OutOfMemory;
    var files = try std.ArrayList(modules.File).initCapacity(allocator, capacity);

    files.appendSliceAssumeCapacity(bundle.modules);

    for (bundle.public_modules) |*facade| files.appendAssumeCapacity(facade.file);

    const entry = try append(allocator, &files, mapped.objects, mapped.services, options);

    const generated = modules.Bundle{
        .arena = bundle.arena,
        .entry = entry,
        .types = bundle.types,
        .modules = files.items,
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

    const owned = arena.allocator();
    var files = try std.ArrayList(modules.File).initCapacity(owned, storage_module_count);
    const entry = try append(owned, &files, &.{}, &.{}, options);

    return .{ .arena = arena, .entry = entry, .types = "", .modules = files.items };
}

fn append(allocator: std.mem.Allocator, files: *std.ArrayList(modules.File), objects: []const generating.zx.state.Object, services: []const generating.gateway.Service, options: Options) !modules.File {
    const prefixed = @import("imports.zig").prefixed;
    const state_imports = try prefixed(allocator, "application=gateway_storage_contract", objects);
    const initial_imports = state_imports[1..];

    files.appendAssumeCapacity(.{ .name = "gateway_storage_contract", .source = try generating.gateway.storage.render(allocator, initial_imports), .imports = initial_imports });
    files.appendAssumeCapacity(.{ .name = "zxc_gateway_state", .source = try generating.zx.state.renderStorage(allocator, objects), .imports = state_imports });

    const imports = try prefixed(allocator, "zxc_gateway_state", services);

    return .{
        .name = "application",
        .imports = imports,
        .source = try generating.gateway.entry.render(allocator, .{ .services = services, .service_modules = imports[1..], .routes = options.routes, .listen = options.listen, .max_header_bytes = options.max_header_bytes, .max_body_bytes = options.max_body_bytes }),
    };
}
