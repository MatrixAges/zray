const std = @import("std");
const zx = @import("zx");
const memory = zx.memory;
const generated = @import("parser_options").generated_parser;
const Route = @import("genz").gateway.Route;
const Export = @import("../../../library/root.zig").Export;
const Error = std.mem.Allocator.Error || error{MissingGatewayService};

/// Gateway analysis and library linking both publish services in input order.
pub fn bind(allocator: std.mem.Allocator, definition: anytype, exports: []const Export) Error![]const Route {
    if (!ordered(definition, exports)) return error.MissingGatewayService;

    const routes = try allocator.alloc(Route, definition.routes.len);

    if (comptime generated) {
        publish(definition.routes, routes);

        return routes;
    }

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
    if (comptime !generated) {
        if (definition.service_routes.len != exports.len) return false;

        for (definition.service_routes, exports) |route, *entry| {
            if (!std.mem.eql(u8, definition.routes[route].service, entry.name)) return false;
        }

        return true;
    }

    const rule = @import("generated_gateway_route_services");
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

fn publish(rows: anytype, routes: []Route) void {
    const rule = @import("generated_gateway_route_publish");
    const Method = @typeInfo(@FieldType(std.meta.Child(@TypeOf(rows)), "method")).optional.child;

    const names = comptime block: {
        const fields = std.meta.fieldNames(Method);
        var result: [fields.len][]const u8 = undefined;

        for (fields) |name| result[@backingInt(@field(Method, name))] = name;

        break :block result;
    };

    const paths = memory.borrowTextColumn("path", rows);
    const methods = memory.borrowOptionalU8Column("method", rows);
    const services = memory.borrowReadColumn(u32, "service_index", rows);
    const output_paths = memory.borrowWriteColumn([]const u8, "path", routes);
    const output_methods = memory.borrowWriteColumn(?[]const u8, "method", routes);
    const output_services = memory.borrowWriteColumn(u64, "service", routes);

    const input: std.meta.Child(rule.Input) = .{
        .count = rows.len,
        .paths = @ptrCast(&paths),
        .methods = @ptrCast(&methods),
        .services = @ptrCast(&services),
        .method_names = &names,
        .output_paths = @ptrCast(&output_paths),
        .output_methods = @ptrCast(&output_methods),
        .output_services = @ptrCast(&output_services),
    };

    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    rule.executeIn(scratch.allocator(), &input) catch unreachable;
}
