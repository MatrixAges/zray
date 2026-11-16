const std = @import("std");
const zx = @import("zx");
const Route = @import("genz").gateway.Route;
const Export = @import("../../../library/root.zig").Export;
const Error = std.mem.Allocator.Error || error{MissingGatewayService};

/// Gateway analysis and library linking both publish services in input order.
pub fn bind(allocator: std.mem.Allocator, definition: anytype, exports: []const Export) Error![]const Route {
    if (!ordered(definition, exports)) return error.MissingGatewayService;

    const routes = try allocator.alloc(Route, definition.routes.len);

    for (definition.routes, routes) |*route, *target| {
        target.* = .{
            .path = route.path,
            .method = if (route.method) |method| @tagName(method) else null,
            .service = route.service_index,
        };
    }

    return routes;
}

fn ordered(definition: anytype, exports: []const Export) bool {
    if (!@import("parser_options").generated_parser) {
        if (definition.service_routes.len != exports.len) return false;

        for (definition.service_routes, exports) |route, *entry| {
            if (!std.mem.eql(u8, definition.routes[route].service, entry.name)) return false;
        }

        return true;
    }

    const rule = @import("generated_gateway_route_services");
    const memory = @import("zx").memory;
    const route_names = memory.borrowTextColumn("service", definition.routes);
    const export_names = memory.borrowTextColumn("name", exports);

    const input: std.meta.Child(rule.Input) = .{
        .routes = @ptrCast(&route_names),
        .first_routes = definition.service_routes,
        .exports = @ptrCast(&export_names),
        .export_count = exports.len,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;
}
