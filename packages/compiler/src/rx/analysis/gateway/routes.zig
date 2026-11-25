const std = @import("std");
const dsl = @import("dsl");
const rx = @import("rx");
const zx = @import("zx");
const target = @import("../call/target.zig");

pub const Route = struct {
    path: []const u8,
    method: ?rx.gateway.Method,
    service: []const u8,
    service_index: u32 = 0,
    location: rx.ast.Location,
};

pub const Collected = struct { routes: []const Route = &.{}, service_routes: []const u32 = &.{} };

const Row = struct {
    node: *const rx.ast.Node,
    parent: ?u32,
    group: bool,
    part: []const u8,
    method: ?u32,
};

pub fn collect(allocator: std.mem.Allocator, backing: std.mem.Allocator, owner: []const u8, node: rx.ast.Node, reporter: *dsl.Reporter) dsl.Error!Collected {
    if (node.children.len == 0) return .{};

    var scratch = std.heap.ArenaAllocator.init(backing);

    defer scratch.deinit();

    const temporary = scratch.allocator();
    var rows: std.MultiArrayList(Row) = .empty;

    try flatten(temporary, &rows, node.children, null);

    const nodes = rows.items(.node);
    const parents = rows.items(.parent);
    const groups = rows.items(.group);
    const parts = rows.items(.part);
    const methods = rows.items(.method);
    const layout = @import("generated_rx_gateway_layout").executeValue(temporary, &.{ .parts = parts, .groups = groups, .parents = parents }) catch |err| return generatedError(err);
    const size = std.math.cast(usize, layout.bytes) orelse return error.OutOfMemory;
    const buffer = try allocator.alloc(u8, size);

    try writePaths(parts, groups, parents, layout.lengths, buffer);

    const lengths = layout.lengths;
    const paths = try temporary.alloc([]const u8, lengths.len);
    const services = try temporary.alloc(?[]const u8, lengths.len);
    var offset: usize = 0;

    for (lengths, paths, services, 0..) |length, *path, *service, row| {
        path.* = "";
        service.* = null;

        if (groups[row]) continue;

        const end = offset + @as(usize, @intCast(length));

        path.* = buffer[offset..end];
        offset = end;

        service.* = rx.resolveModulePath(temporary, owner, target.attribute(nodes[row].*, "service").value) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;

            continue;
        };
    }

    const conflicts = @import("generated_rx_gateway_conflicts").executeValue(temporary, &.{
        .paths = paths,
        .groups = groups,
        .methods = methods,
        .services = services,
    }) catch |err| return generatedError(err);

    switch (conflicts.issue) {
        .None => {},
        .Overlap => return fail(nodes[@intCast(conflicts.row)].*, "path", "Gateway routes overlap after Group prefix expansion", reporter),
        .Service => return fail(nodes[@intCast(conflicts.row)].*, "service", "Gateway service must resolve to an ordinary module inside the project", reporter),
    }

    if (lengths.len != rows.len) {
        const key = if (groups[lengths.len]) "prefix" else "path";

        return fail(nodes[lengths.len].*, key, "Gateway paths must be absolute literal paths without query, fragment, parameters or wildcards", reporter);
    }

    const routes = try allocator.alloc(Route, @intCast(layout.routes));
    var next: usize = 0;

    for (nodes, paths, services, groups, methods) |source, path, service, group, method| {
        if (group) continue;

        const service_index = conflicts.route_services[next];
        const first = conflicts.service_routes[service_index];
        const name = if (first == next) try allocator.dupe(u8, service.?) else routes[first].service;

        routes[next] = .{
            .path = path,
            .method = if (method) |tag| @as(rx.gateway.Method, @fromBackingInt(@intCast(tag))) else null,
            .service = name,
            .service_index = service_index,
            .location = source.location,
        };

        next += 1;
    }

    return .{ .routes = routes, .service_routes = try allocator.dupe(u32, conflicts.service_routes) };
}

fn flatten(allocator: std.mem.Allocator, rows: *std.MultiArrayList(Row), nodes: []const rx.ast.Node, parent: ?u32) std.mem.Allocator.Error!void {
    for (nodes) |*node| {
        const group = std.mem.eql(u8, node.name, "Group");
        const key = if (group) "prefix" else "path";
        const method = if (target.optionalAttribute(node.*, "method")) |value| std.meta.stringToEnum(rx.gateway.Method, value.value).? else null;
        const row = std.math.cast(u32, rows.len) orelse return error.OutOfMemory;

        try rows.append(allocator, .{
            .node = node,
            .parent = parent,
            .group = group,
            .part = target.attribute(node.*, key).value,
            .method = if (method) |value| @backingInt(value) else null,
        });

        if (group) try flatten(allocator, rows, node.children, row);
    }
}

fn writePaths(parts: []const []const u8, groups: []const bool, parents: []const ?u32, lengths: []const u64, target_buffer: []u8) std.mem.Allocator.Error!void {
    if (target_buffer.len == 0) return;

    const rule = @import("generated_rx_gateway_write_routes");
    const Input = std.meta.Child(rule.Input);
    var buffer = target_buffer;
    const input: Input = .{ .parts = parts, .groups = groups, .parents = parents, .lengths = lengths, .target = @ptrCast(&buffer) };
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const written = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch |err| return generatedError(err);

    std.debug.assert(written == target_buffer.len);
}

fn generatedError(err: anyerror) std.mem.Allocator.Error {
    return switch (err) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => error.OutOfMemory,
        else => unreachable,
    };
}

fn fail(node: rx.ast.Node, key: []const u8, message: []const u8, reporter: *dsl.Reporter) dsl.Error {
    return reporter.fail(.{ .code = .context, .location = target.attribute(node, key).value_location, .element = node.name, .attribute = key, .message = message });
}
