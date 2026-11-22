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

const Scan = struct {
    collector: *Collector,
    owner: []const u8 = "",
    entries: ?[]const Entry = null,
    path: []u8 = &.{},
    fn borrow(handle: *const anyopaque) *Scan {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
    fn site(self: *const Scan, index: u64) Site {
        const row: usize = @intCast(index);
        const entries = self.entries orelse return .{ .location = position.deferred(row), .role = .dependency };
        const entry = &entries[row];

        return .{
            .location = if (entry.attribute) |attribute| attribute.value_location else entry.node.location,
            .role = Reference.fromXml(entry.role),
        };
    }
};

pub fn collectRx(collector: *Collector, owner: []const u8, entries: []const Entry) Collector.Error!void {
    if (entries.len == 0) return;

    const rule = @import("generated_rx_scan_source_graph_references");
    const values = zx.memory.borrowIndirectTextColumn("attribute", "value", entries);
    const packages = zx.memory.borrowReadColumn(bool, "package_allowed", entries);
    const specifiers = zx.memory.borrowTextColumn("specifier", collector.dependencies());
    var buffer: [512]u8 = undefined;
    var scan: Scan = .{ .collector = collector, .owner = owner, .entries = entries, .path = &buffer };

    const input: std.meta.Child(rule.Input) = .{
        .target = @ptrCast(&scan),
        .directory = std.fs.path.dirname(owner) orelse ".",
        .packages = &.{ .items = @ptrCast(&specifiers), .length = specifiers.count },
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

pub fn growSourceGraphPath(handle: *const anyopaque, count: u64) std.mem.Allocator.Error![]const u8 {
    const self = Scan.borrow(handle);
    const size = std.math.cast(usize, count) orelse return error.OutOfMemory;

    self.path = try self.collector.temporary.allocator().alloc(u8, size);

    return self.path;
}

pub fn rejectSourceGraphReference(handle: *const anyopaque, index: u64, message: []const u8) Collector.Error!void {
    const self = Scan.borrow(handle);

    return self.collector.fail(self.site(index).location, message);
}

pub fn resolveSourceGraphReference(handle: *const anyopaque, index: u64, length: u64, store: bool) Collector.Error!void {
    const self = Scan.borrow(handle);
    const entry = &self.entries.?[@intCast(index)];
    const path = self.path[0..@intCast(length)];

    if (store) return self.collector.store(path, entry.attribute.?.value_location, self.owner);

    return @import("../rx_edges.zig").local(self.collector, path, entry.*);
}

pub fn sourceGraphInternal(handle: *const anyopaque, specifier: []const u8) ?[]const u8 {
    const self = Scan.borrow(handle);

    return if (self.collector.options.internalModule(specifier)) |entry| entry.key() else null;
}

pub fn appendSourceGraphNative(handle: *const anyopaque, index: u64, name: []const u8) Collector.Error!void {
    const self = Scan.borrow(handle);
    const site = self.site(index);

    try self.collector.nativeImport(name, site.location, site.role);
}

pub fn resolveSourceGraphImport(handle: *const anyopaque, index: u64, specifier: []const u8, package: bool, first: ?u64, duplicate: bool) Collector.Error!void {
    const self = Scan.borrow(handle);
    const site = self.site(index);

    const selected: ?project.PackageMatch = if (package) .{
        .first = if (first) |row| @intCast(row) else null,
        .duplicate = duplicate,
    } else null;

    try self.collector.resolveImport(specifier, site.location, site.role, if (package) .Package else .File, selected);
}
