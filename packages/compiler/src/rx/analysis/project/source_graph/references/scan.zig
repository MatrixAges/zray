const std = @import("std");
const rx = @import("rx");
const zx = @import("zx");
const project = @import("frontend").project;
const Collector = @import("../collect.zig");
const Reference = @import("../model.zig").Reference;
const position = @import("../position.zig");
const Entry = rx.dependency_reference.Entry;
const Target = @FieldType(Entry, "target");
const Location = rx.ast.Location;

comptime {
    std.debug.assert(@sizeOf(Target) == 1);
    std.debug.assert(@backingInt(Target.Module) == 0 and @backingInt(Target.Function) == 1 and @backingInt(Target.Store) == 2);
}

const Site = struct { location: Location, role: Reference };

const Delivery = union(enum) {
    diagnostic: []const u8,
    source: []const u8,
    store: []const u8,
    package: struct { specifier: []const u8, selected: ?project.PackageMatch },
};

const ExternalCollector = struct {
    context: *anyopaque,
    apply: *const fn (*anyopaque, *const Entry, []const u8, Delivery) anyerror!void,
    fn bind(collector: anytype) ExternalCollector {
        const Pointer = @TypeOf(collector);

        const Adapter = struct {
            fn apply(context: *anyopaque, entry: *const Entry, owner: []const u8, delivery: Delivery) anyerror!void {
                const target: Pointer = @ptrCast(@alignCast(context));
                const location = if (entry.attribute) |attribute| attribute.value_location else entry.node.location;

                switch (delivery) {
                    .diagnostic => |message| return target.fail(location, message),
                    .source => |path| try @import("../rx_edges.zig").local(target, path, entry.*),
                    .store => |path| try target.store(path, location, owner),
                    .package => |binding| try target.import(binding.specifier, location, Reference.fromXml(entry.role), binding.selected),
                }
            }
        };

        return .{ .context = collector, .apply = Adapter.apply };
    }
};

const Scan = struct {
    collector: ?*Collector = null,
    external: ?ExternalCollector = null,
    failure: ?anyerror = null,
    owner: []const u8 = "",
    entries: ?[]const Entry = null,
    tree: ?Entry = null,
    path: []u8 = &.{},
    fn borrow(handle: *const anyopaque) *Scan {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
    fn site(self: *const Scan, index: u64) Site {
        const entry = self.reference(index) orelse return .{ .location = position.deferred(@intCast(index)), .role = .dependency };

        return .{
            .location = if (entry.attribute) |attribute| attribute.value_location else entry.node.location,
            .role = Reference.fromXml(entry.role),
        };
    }
    fn reference(self: *const Scan, index: u64) ?*const Entry {
        if (self.entries) |entries| return &entries[@intCast(index)];
        if (self.tree) |*entry| return entry;

        return null;
    }

    fn send(self: *Scan, external: ExternalCollector, index: u64, delivery: Delivery) Collector.Error!void {
        external.apply(external.context, self.reference(index).?, self.owner, delivery) catch |err| {
            self.failure = err;

            return error.InvalidGraph;
        };
    }
};

pub fn collect(collector: anytype, source: rx.ModuleSource) @TypeOf(collector.*).Error!void {
    const indexed = source.indexedReferences();

    if (indexed != null and indexed.?.len == 0) return;

    var buffer: [512]u8 = undefined;
    var scan: Scan = .{ .owner = source.path, .entries = indexed, .path = &buffer };

    if (comptime @TypeOf(collector) == *Collector) {
        scan.collector = collector;
    } else {
        scan.external = ExternalCollector.bind(collector);
    }

    const packages = collector.dependencies();
    const allocator = collector.temporary.allocator();
    const result = if (indexed) |entries| collectIndexed(&scan, packages, allocator, entries) else collectTree(&scan, packages, allocator, &source.node);

    return result catch |err| {
        if (comptime @TypeOf(collector) == *Collector) return err;

        return @errorCast(scan.failure orelse err);
    };
}

fn collectIndexed(scan: *Scan, dependencies: []const project.Package, allocator: std.mem.Allocator, entries: []const Entry) Collector.Error!void {
    if (entries.len == 0) return;

    const rule = @import("generated_rx_scan_source_graph_references");
    const values = zx.memory.borrowIndirectTextColumn("attribute", "value", entries);
    const packages = zx.memory.borrowReadColumn(bool, "package_allowed", entries);
    const specifiers = zx.memory.borrowTextColumn("specifier", dependencies);

    const input: std.meta.Child(rule.Input) = .{
        .target = @ptrCast(scan),
        .directory = std.fs.path.dirname(scan.owner) orelse ".",
        .packages = &.{ .items = @ptrCast(&specifiers), .length = specifiers.count },
        .allocator = @ptrCast(&allocator),
        .delegate_import = scan.external != null,
        .workspace = &.{ .bytes = scan.path, .target = @ptrCast(&scan.path), .start = 0 },
        .references = &.{
            .values = @ptrCast(&values),
            .package_allowed = @ptrCast(&packages),
            .target_codes = std.mem.sliceAsBytes(entries)[@offsetOf(Entry, "target")..],
            .stride = @sizeOf(Entry),
            .count = entries.len,
        },
    };

    try execute(rule, &input);
}

fn collectTree(scan: *Scan, dependencies: []const project.Package, allocator: std.mem.Allocator, node: *const rx.ast.Node) Collector.Error!void {
    const rule = @import("generated_rx_scan_source_graph_tree");
    const Input = std.meta.Child(rule.Input);
    const specifiers = zx.memory.borrowTextColumn("specifier", dependencies);
    var cursor: rx.dependency_reference.Tree.Cursor = .{};

    defer cursor.deinit(allocator);
    cursor.reset(node);

    const input: Input = .{
        .target = @ptrCast(scan),
        .directory = std.fs.path.dirname(scan.owner) orelse ".",
        .packages = &.{ .items = @ptrCast(&specifiers), .length = specifiers.count },
        .allocator = @ptrCast(&allocator),
        .delegate_import = scan.external != null,
        .workspace = &.{ .bytes = scan.path, .target = @ptrCast(&scan.path), .start = 0 },
        .cursor = &cursor.borrow(std.meta.Child(@FieldType(Input, "cursor")), &allocator),
        .attribute_value = @offsetOf(rx.ast.Attribute, "value"),
        .intrinsic = project.intrinsic_import,
    };

    try execute(rule, &input);
}

pub fn collectZx(collector: *Collector, header: anytype) Collector.Error!void {
    const imports = header.storage.imports;

    if (imports.len == 0) return;

    const rule = @import("generated_rx_scan_source_graph_imports");
    const Input = std.meta.Child(rule.Input);
    const packages = zx.memory.borrowTextColumn("specifier", collector.dependencies());
    var scan: Scan = .{ .collector = collector };

    const input: Input = .{
        .target = @ptrCast(&scan),
        .source = header.source,
        .intrinsic = project.intrinsic_import,
        .packages = &.{ .items = @ptrCast(&packages), .length = packages.count },
        .imports = zx.columns.slice(@FieldType(Input, "imports"), imports),
    };

    try execute(rule, &input);
}

fn execute(comptime rule: type, input: *const std.meta.Child(rule.Input)) Collector.Error!void {
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    zx.columns.invoke(rule.executeValue, empty.allocator(), input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        error.InvalidGraph => return error.InvalidGraph,
        else => unreachable,
    };
}

pub fn bindSourceGraphTreeReference(handle: *const anyopaque, node: []const u8, attribute: ?[]const u8, function_target: bool, call: bool, type_import: bool) void {
    Scan.borrow(handle).tree = .{
        .node = @ptrCast(@alignCast(node.ptr)),
        .attribute = if (attribute) |view| @ptrCast(@alignCast(view.ptr)) else null,
        .target = if (function_target) .Function else .Module,
        .role = if (call) .Call else if (type_import) .TypeImport else .Dependency,
    };
}

pub fn rejectSourceGraphReference(handle: *const anyopaque, index: u64, message: []const u8) Collector.Error!void {
    const self = Scan.borrow(handle);

    if (self.external) |external| return self.send(external, index, .{ .diagnostic = message });

    return self.collector.?.fail(self.site(index).location, message);
}

pub fn resolveSourceGraphReference(handle: *const anyopaque, index: u64, length: u64, store: bool) Collector.Error!void {
    const self = Scan.borrow(handle);
    const path = self.path[0..@intCast(length)];

    if (self.external) |external| return self.send(external, index, if (store) .{ .store = path } else .{ .source = path });

    const entry = self.reference(index).?;

    if (store) return self.collector.?.store(path, entry.attribute.?.value_location, self.owner);

    return @import("../rx_edges.zig").local(self.collector.?, path, entry.*);
}

pub fn sourceGraphInternal(handle: *const anyopaque, specifier: []const u8) ?[]const u8 {
    const self = Scan.borrow(handle);

    return if (self.collector.?.options.internalModule(specifier)) |entry| entry.key() else null;
}

pub fn appendSourceGraphNative(handle: *const anyopaque, index: u64, name: []const u8) Collector.Error!void {
    const self = Scan.borrow(handle);
    const site = self.site(index);

    try self.collector.?.nativeImport(name, site.location, site.role);
}

pub fn resolveSourceGraphImport(handle: *const anyopaque, index: u64, specifier: []const u8, package: bool, first: ?u64, duplicate: bool) Collector.Error!void {
    const self = Scan.borrow(handle);

    const selected: ?project.PackageMatch = if (package) .{
        .first = if (first) |row| @intCast(row) else null,
        .duplicate = duplicate,
    } else null;

    if (self.external) |external| return self.send(external, index, .{ .package = .{ .specifier = specifier, .selected = selected } });

    const site = self.site(index);

    try self.collector.?.resolveImport(specifier, site.location, site.role, if (package) .Package else .File, selected);
}
