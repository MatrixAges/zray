const std = @import("std");
const zx = @import("zx");
const memory = zx.memory;
const Route = @import("genz").gateway.Route;
const Export = @import("../../../library/root.zig").Export;
const Error = std.mem.Allocator.Error || error{MissingGatewayService};

/// Gateway analysis and library linking both publish services in input order.
pub fn bind(allocator: std.mem.Allocator, definition: anytype, exports: []const Export) Error![]const Route {
    if (!ordered(definition, exports)) return error.MissingGatewayService;

    const routes = try allocator.alloc(Route, definition.routes.len);

    try publish(allocator, definition.routes, routes);

    return routes;
}

fn ordered(definition: anytype, exports: []const Export) bool {
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

fn publish(allocator: std.mem.Allocator, rows: anytype, routes: []Route) std.mem.Allocator.Error!void {
    if (rows.len == 0) return;

    const rule = @import("generated_gateway_route_publish");
    const Method = @typeInfo(@FieldType(std.meta.Child(@TypeOf(rows)), "method")).optional.child;

    const names = comptime block: {
        const fields = std.meta.fieldNames(Method);
        var result: [fields.len][]const u8 = undefined;

        for (fields) |name| result[@backingInt(@field(Method, name))] = name;

        break :block result;
    };

    var scratch = std.heap.ArenaAllocator.init(allocator);

    defer scratch.deinit();

    const source = memory.borrowReadFields(.{ .paths = "path", .services = "service_index" }, rows);
    const methods = memory.borrowOptionalU8Column("method", rows);
    var input: std.meta.Child(rule.Input) = undefined;

    source.fill(&input);

    input.methods = @ptrCast(&methods);
    input.method_names = &names;

    const request = input;

    const published = zx.columns.invoke(rule.executeValue, scratch.allocator(), &request) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    for (published, 0..) |item, i| {
        routes[i] = .{
            .path = item.path,
            .method = item.method,
            .service = @intCast(item.service),
        };
    }
}
