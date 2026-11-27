const std = @import("std");
const rx = @import("rx");
const zx = @import("zx");
const project = @import("frontend").project;
const Collector = @import("../collect.zig");
const Reference = @import("../model.zig").Reference;
const position = @import("../position.zig");
const rule = @import("generated_rx_scan_source_graph");
const Input = std.meta.Child(rule.Input);
const Deliveries = @typeInfo(@TypeOf(rule.executeValue(undefined, undefined))).error_union.payload;
const Delivery = std.meta.Elem(Deliveries);
const Cursor = rx.dependency_reference.Tree.Cursor;
const Entry = rx.dependency_reference.Entry;
const Target = @FieldType(Entry, "target");
const Role = @FieldType(Entry, "role");
const Location = rx.ast.Location;

comptime {
    std.debug.assert(@sizeOf(Target) == 1 and @sizeOf(Role) == 1);
    std.debug.assert(@backingInt(Target.Module) == 0 and @backingInt(Target.Function) == 1 and @backingInt(Target.Store) == 2);
    std.debug.assert(@backingInt(Role.Dependency) == @backingInt(Reference.dependency));
    std.debug.assert(@backingInt(Role.Call) == @backingInt(Reference.call));
    std.debug.assert(@backingInt(Role.TypeImport) == @backingInt(Reference.type_import));
}

pub fn collect(collector: anytype, source: rx.ModuleSource) @TypeOf(collector.*).Error!void {
    const indexed = source.indexedReferences();

    if (indexed != null and indexed.?.len == 0) return;

    const discovering = @TypeOf(collector) != *Collector;
    const options: ?*const project.Options = if (discovering) null else &collector.options;
    const packages = zx.memory.borrowTextColumn("specifier", collector.dependencies());
    const allocator = collector.temporary.allocator();
    var cursor: Cursor = .{};

    defer cursor.deinit(allocator);

    if (indexed == null) cursor.reset(&source.node);

    const Tree = std.meta.Child(std.meta.Child(@FieldType(Input, "cursor")));
    const Layout = std.meta.Child(@FieldType(Tree, "layout"));

    try execute(collector, &.{
        .scan = &.{
            .internal = if (options) |value| @ptrCast(value) else null,
            .packages = &.{ .items = @ptrCast(&packages), .length = packages.count },
            .intrinsic = if (indexed == null) project.intrinsic_import else null,
            .discover = discovering,
        },
        .xml = &.{
            .owner = source.path,
            .directory = std.fs.path.dirname(source.path) orelse ".",
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

    const discovering = @TypeOf(collector) != *Collector;
    const options: ?*const project.Options = if (discovering) null else &collector.options;
    const packages = zx.memory.borrowTextColumn("specifier", collector.dependencies());
    const Imports = std.meta.Child(std.meta.Child(@FieldType(Input, "imports")));

    try execute(collector, &.{
        .scan = &.{
            .internal = if (options) |value| @ptrCast(value) else null,
            .packages = &.{ .items = @ptrCast(&packages), .length = packages.count },
            .intrinsic = project.intrinsic_import,
            .discover = discovering,
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

fn execute(collector: anytype, input: *const Input) @TypeOf(collector.*).Error!void {
    var buffer: [512]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, collector.temporary.allocator());

    const deliveries = zx.columns.invoke(rule.executeValue, scratch.allocator(), input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    for (deliveries) |delivery| try apply(collector, delivery);
}

fn apply(collector: anytype, delivery: Delivery) @TypeOf(collector.*).Error!void {
    const discovering = @TypeOf(collector) != *Collector;

    const location = if (delivery.location) |bytes|
        @as(*const Location, @ptrCast(@alignCast(bytes.ptr))).*
    else
        position.imported(@intCast(delivery.offset), discovering);

    const role: Reference = @fromBackingInt(@intCast(delivery.role));

    const selection: ?project.PackageMatch = if (delivery.package_route) .{
        .first = if (delivery.first) |row| @intCast(row) else null,
        .duplicate = delivery.duplicate,
    } else null;

    return switch (delivery.kind) {
        .Diagnostic => collector.fail(location, delivery.value.?),
        .Source => if (delivery.member) |member|
            collector.qualified(delivery.path.?, member, location)
        else
            collector.local(delivery.path.?, location, role),
        .Store => collector.store(delivery.path.?, location, delivery.value.?),
        .Import => if (comptime discovering)
            collector.import(delivery.value.?, location, role, selection)
        else
            collector.resolveImport(delivery.value.?, location, role, if (delivery.package_route) .Package else .File, selection),
        .Native => if (comptime discovering) unreachable else collector.nativeImport(delivery.value.?, location, role),
    };
}

pub fn sourceGraphInternal(handle: *const anyopaque, specifier: []const u8) ?[]const u8 {
    const options: *const project.Options = @ptrCast(@alignCast(handle));

    return if (options.internalModule(specifier)) |entry| entry.key() else null;
}
