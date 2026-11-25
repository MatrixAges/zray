const std = @import("std");
const rx = @import("rx");
const zx = @import("zx");
const project = @import("frontend").project;
const Collector = @import("../collect.zig");
const Reference = @import("../model.zig").Reference;
const position = @import("../position.zig");
const rule = @import("generated_rx_scan_source_graph");
const Kind = @import("rx_execution_abi").layouts.@"zig:rx_graph_host".GraphReferenceKind;
const Input = std.meta.Child(rule.Input);
const Cursor = rx.dependency_reference.Tree.Cursor;
const Entry = rx.dependency_reference.Entry;
const Target = @FieldType(Entry, "target");
const Role = @FieldType(Entry, "role");
const Location = rx.ast.Location;

const Delivery = struct {
    kind: Kind,
    location: Location,
    role: Reference,
    value: ?[]const u8,
    path: ?[]const u8,
    member: ?[]const u8,
    selection: ?project.PackageMatch,
};

comptime {
    std.debug.assert(@sizeOf(Target) == 1 and @sizeOf(Role) == 1);
    std.debug.assert(@backingInt(Target.Module) == 0 and @backingInt(Target.Function) == 1 and @backingInt(Target.Store) == 2);
    std.debug.assert(@backingInt(Role.Dependency) == @backingInt(Reference.dependency));
    std.debug.assert(@backingInt(Role.Call) == @backingInt(Reference.call));
    std.debug.assert(@backingInt(Role.TypeImport) == @backingInt(Reference.type_import));
}

const Scan = struct {
    graph: ?*Collector = null,
    collector: *anyopaque = undefined,
    discovery: *const fn (*anyopaque, *const Delivery) anyerror!void = undefined,
    failure: ?anyerror = null,
    fn bind(collector: anytype) Scan {
        if (comptime @TypeOf(collector) == *Collector) return .{ .graph = collector };

        const Adapter = struct {
            fn publish(context: *anyopaque, delivery: *const Delivery) anyerror!void {
                const target: @TypeOf(collector) = @ptrCast(@alignCast(context));

                try apply(target, delivery);
            }
        };

        return .{ .collector = collector, .discovery = Adapter.publish };
    }
    fn borrow(handle: *anyopaque) *Scan {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn collect(collector: anytype, source: rx.ModuleSource) @TypeOf(collector.*).Error!void {
    const indexed = source.indexedReferences();

    if (indexed != null and indexed.?.len == 0) return;

    var scan = Scan.bind(collector);
    const packages = zx.memory.borrowTextColumn("specifier", collector.dependencies());
    const allocator = collector.temporary.allocator();
    var buffer: [512]u8 = undefined;
    var workspace: []u8 = &buffer;
    var cursor: Cursor = .{};

    defer cursor.deinit(allocator);

    if (indexed == null) cursor.reset(&source.node);

    const Tree = std.meta.Child(std.meta.Child(@FieldType(Input, "cursor")));
    const Layout = std.meta.Child(@FieldType(Tree, "layout"));

    try execute(collector, &scan, &.{
        .scan = &.{
            .target = @ptrCast(&scan),
            .packages = &.{ .items = @ptrCast(&packages), .length = packages.count },
            .intrinsic = if (indexed == null) project.intrinsic_import else null,
            .discover = scan.graph == null,
        },
        .xml = &.{
            .owner = source.path,
            .directory = std.fs.path.dirname(source.path) orelse ".",
            .allocator = @ptrCast(&allocator),
            .workspace = &.{ .bytes = workspace, .target = @ptrCast(&workspace), .start = 0 },
            .layout = &comptime rx.astLayout(Layout),
        },
        .indexed = if (indexed) |entries| &.{
            .bytes = std.mem.sliceAsBytes(entries),
            .width = @sizeOf(Entry),
            .node = @offsetOf(Entry, "node"),
            .attribute = @offsetOf(Entry, "attribute"),
            .target = @offsetOf(Entry, "target"),
            .role = @offsetOf(Entry, "role"),
            .package_allowed = @offsetOf(Entry, "package_allowed"),
            .node_width = @sizeOf(rx.ast.Node),
            .attribute_width = @sizeOf(rx.ast.Attribute),
            .count = entries.len,
        } else null,
        .cursor = if (indexed == null) &cursor.borrow(Tree, &allocator) else null,
        .imports = null,
    });
}

pub fn collectZx(collector: anytype, header: anytype) @TypeOf(collector.*).Error!void {
    const imports = header.storage.imports;

    if (imports.len == 0) return;

    var scan = Scan.bind(collector);
    const packages = zx.memory.borrowTextColumn("specifier", collector.dependencies());
    const Imports = std.meta.Child(std.meta.Child(@FieldType(Input, "imports")));

    try execute(collector, &scan, &.{
        .scan = &.{
            .target = @ptrCast(&scan),
            .packages = &.{ .items = @ptrCast(&packages), .length = packages.count },
            .intrinsic = project.intrinsic_import,
            .discover = scan.graph == null,
        },
        .xml = null,
        .indexed = null,
        .cursor = null,
        .imports = &.{
            .source = header.source,
            .rows = zx.columns.slice(@FieldType(Imports, "rows"), imports),
        },
    });
}

fn execute(collector: anytype, scan: *Scan, input: *const Input) @TypeOf(collector.*).Error!void {
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    rule.executeIn(empty.allocator(), input) catch |err| {
        if (comptime @TypeOf(collector) != *Collector) {
            if (scan.failure) |failure| return @errorCast(failure);
        }

        return switch (@as(anyerror, err)) {
            error.OutOfMemory, error.Overflow => error.OutOfMemory,
            error.InvalidGraph => error.InvalidGraph,
            else => unreachable,
        };
    };
}

fn apply(collector: anytype, delivery: *const Delivery) @TypeOf(collector.*).Error!void {
    const discovering = @TypeOf(collector) != *Collector;
    const location = delivery.location;
    const role = delivery.role;

    return switch (delivery.kind) {
        .Diagnostic => collector.fail(location, delivery.value.?),
        .Source => if (delivery.member) |member|
            collector.qualified(delivery.path.?, member, location)
        else
            collector.local(delivery.path.?, location, role),
        .Store => collector.store(delivery.path.?, location, delivery.value.?),
        .Import => if (comptime discovering)
            collector.import(delivery.value.?, location, role, delivery.selection)
        else
            collector.resolveImport(delivery.value.?, location, role, if (delivery.selection != null) .Package else .File, delivery.selection),
        .Native => if (comptime discovering) unreachable else collector.nativeImport(delivery.value.?, location, role),
    };
}

pub fn deliverSourceGraphReference(
    handle: *anyopaque,
    kind: Kind,
    borrowed_location: ?[]const u8,
    offset: u64,
    role: u8,
    value: ?[]const u8,
    path: ?[]const u8,
    member: ?[]const u8,
    package_route: bool,
    first: ?u64,
    duplicate: bool,
) Collector.Error!void {
    const scan = Scan.borrow(handle);

    const location = if (borrowed_location) |bytes|
        @as(*const Location, @ptrCast(@alignCast(bytes.ptr))).*
    else
        position.imported(@intCast(offset), scan.graph == null);

    const delivery: Delivery = .{
        .kind = kind,
        .location = location,
        .role = @enumFromInt(role),
        .value = value,
        .path = path,
        .member = member,
        .selection = if (package_route) .{ .first = if (first) |row| @intCast(row) else null, .duplicate = duplicate } else null,
    };

    if (scan.graph) |collector| return apply(collector, &delivery);

    scan.discovery(scan.collector, &delivery) catch |err| {
        scan.failure = err;

        return error.InvalidGraph;
    };
}

pub fn sourceGraphInternal(handle: *anyopaque, specifier: []const u8) ?[]const u8 {
    const collector = Scan.borrow(handle).graph.?;

    return if (collector.options.internalModule(specifier)) |entry| entry.key() else null;
}
