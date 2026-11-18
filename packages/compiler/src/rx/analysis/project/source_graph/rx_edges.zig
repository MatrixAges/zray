const std = @import("std");
const rx = @import("rx");
const project = @import("frontend").project;
const Reference = @import("model.zig").Reference;
const dependency = rx.dependency_reference;
const generated = @import("rx_options").generated_graph;
const route = if (generated) @import("generated_rx_reference_route") else void;
const RouteInput = if (generated) std.meta.Child(route.Input) else void;
const Resolution = if (generated) @typeInfo(@TypeOf(route.executeValue(undefined, undefined))).error_union.payload else void;
const Route = if (@typeInfo(Resolution) == .pointer) std.meta.Child(Resolution) else Resolution;
const inline_path_bytes = 512;

pub fn collect(collector: anytype, source: rx.ModuleSource) @TypeOf(collector.*).Error!void {
    if (comptime generated) {
        if (source.indexedReferences()) |entries| {
            return @import("references/indexed.zig").collect(collector, source.path, entries);
        }
    }

    var references: dependency.Iterator = .{};
    const temporary = collector.temporary.allocator();
    var inline_path: [inline_path_bytes]u8 = undefined;
    var path: []u8 = &inline_path;
    const directory = std.fs.path.dirname(source.path) orelse ".";

    defer references.deinit(temporary);
    references.reset(&source.node, source.references);

    while (try references.next(temporary, false)) |selection| {
        try reference(collector, source.path, directory, &path, selection);
    }
}

fn reference(collector: anytype, owner: []const u8, directory: []const u8, path: *[]u8, selection: dependency.Entry) @TypeOf(collector.*).Error!void {
    const value = selection.attribute orelse return collector.fail(selection.node.location, "source dependency requires an explicit target");
    const role = Reference.fromXml(selection.role);

    if (comptime !generated) return referenceSeed(collector, owner, selection, value, role);

    const packages = if (selection.package_allowed) collector.dependencies() else &.{};
    const names = @import("zx").memory.borrowTextColumn("specifier", packages);

    const input: RouteInput = .{
        .directory = directory,
        .reference = value.value,
        .target = switch (selection.target) {
            .Module => .Module,
            .Function => .Function,
            .Store => .Store,
        },
        .package_allowed = selection.package_allowed,
        .packages = &.{ .items = @ptrCast(&names), .length = names.count },
        .workspace = undefined,
    };

    var planned = resolve(input, path);

    if (planned.kind == .NeedSpace) {
        const capacity = std.math.cast(usize, planned.length) orelse return error.OutOfMemory;
        path.* = try collector.temporary.allocator().alloc(u8, capacity);
        planned = resolve(input, path);
    }

    switch (planned.kind) {
        .Package => try collector.import(value.value, value.value_location, role, .{
            .first = @intCast(planned.first.?),
            .duplicate = planned.duplicate,
        }),
        .Source => try local(collector, path.*[0..@intCast(planned.length)], selection),
        .Store => try collector.store(path.*[0..@intCast(planned.length)], value.value_location, owner),
        .Invalid => return invalidPath(collector, value.value_location),
        .NeedSpace => unreachable,
    }
}

fn resolve(request: RouteInput, path: *const []u8) Route {
    var input = request;
    var bytes: [@sizeOf(Route)]u8 align(@alignOf(Route)) = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&bytes);

    input.workspace = &.{ .bytes = path.*, .target = @ptrCast(path), .start = 0 };

    const result = @import("zx").columns.invoke(route.executeValue, scratch.allocator(), @as(*const RouteInput, &input)) catch unreachable;

    return if (comptime @typeInfo(Resolution) == .pointer) result.* else result;
}

fn referenceSeed(collector: anytype, owner: []const u8, selection: dependency.Entry, value: *const rx.ast.Attribute, role: Reference) @TypeOf(collector.*).Error!void {
    if (selection.package_allowed) {
        const packages = collector.dependencies();
        const selected = project.matchPackage(packages, value.value, true);

        if (selected.first != null) return collector.import(value.value, value.value_location, role, selected);
    }

    const temporary = collector.temporary.allocator();

    const path = switch (selection.target) {
        .Module => rx.resolveModulePath(temporary, owner, value.value),
        .Function => rx.resolveFunctionPath(temporary, owner, value.value),
        .Store => rx.resolveStorePath(temporary, owner, value.value),
    };

    const resolved = path catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        return invalidPath(collector, value.value_location);
    };

    defer temporary.free(resolved);

    if (selection.target == .Store) return collector.store(resolved, value.value_location, owner);
    try local(collector, resolved, selection);
}

pub fn local(collector: anytype, path: []const u8, entry: dependency.Entry) @TypeOf(collector.*).Error!void {
    const attribute = entry.attribute.?;

    if (entry.role == .Call and entry.target == .Function) {
        if (project.module_path.callMember(attribute.value)) |member| {
            return collector.qualified(path, member, attribute.value_location);
        }
    }

    try collector.local(path, attribute.value_location, Reference.fromXml(entry.role));
}

fn invalidPath(collector: anytype, location: rx.ast.Location) @TypeOf(collector.*).Error {
    return collector.fail(location, "source dependency escapes the project root or is not a valid module path");
}
