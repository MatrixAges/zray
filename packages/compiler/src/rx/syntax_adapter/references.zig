const std = @import("std");
const ast = @import("dsl").ast;
pub const Target = enum { Module, Function, Store };
pub const Role = enum { Dependency, Call, TypeImport };

pub const Entry = struct {
    node: *const ast.Node,
    attribute: ?*const ast.Attribute = null,
    target: Target = .Module,
    role: Role = .Dependency,
    package_allowed: bool = false,
    graph: bool = false,
};

pub const Index = opaque {};

const Storage = struct {
    root: *const ast.Node,
    entries: []const Entry,
    graph_references: usize,
    missing_input: ?*const ast.Node,
    attributes: []const ast.Attribute,
    flow: []const Fact,
    unit_firsts: []const u32,
    unit_counts: []const u32,
    step_rows: []const u32,
    events: []const Event,
    parallel_tasks: usize,
    capacity: Capacity,
    source_extent: usize,
};

pub const Capacity = struct {
    steps: u32,
    calls: u32,
    results: u32,
    tasks: u32,
    groups: u32,
    selections: u32,
};

pub const Action = enum(u3) {
    unsupported,
    call,
    task,
    parallel,
    switch_flow,
    if_flow,
    result,
    declaration,
};

pub const Fact = packed struct(u32) {
    returns: bool,
    terminates: bool,
    unreachable_step: bool,
    declaration: bool,
    alternate: bool,
    action: Action,
    reserved: u24,
};

pub const Event = packed struct(u64) {
    slot: u32,
    phase: enum(u32) { enter, check_task, _ },
};

pub const Flow = struct {
    base: [*]const ast.Node,
    facts: []const Fact,
    unit_firsts: []const u32,
    unit_counts: []const u32,
    step_rows: []const u32,
    events: []const Event,
    parallel_tasks: usize,
    capacity: Capacity,
    pub const Operation = Action;

    pub fn get(self: Flow, node: *const ast.Node) Fact {
        return self.facts[self.row(node)];
    }
    pub fn rootUnit(self: Flow) Unit {
        return self.unit(&self.base[0]);
    }
    pub fn unit(self: Flow, node: *const ast.Node) Unit {
        const index = self.row(node);

        return .{ .first = self.unit_firsts[index], .count = self.unit_counts[index] };
    }
    pub fn row(self: Flow, node: *const ast.Node) usize {
        return (@intFromPtr(node) - @intFromPtr(self.base)) / @sizeOf(ast.Node);
    }

    pub const Unit = struct { first: u32 = 0, count: u32 = 0 };
};

pub fn flowForNode(index: *const Index, node: *const ast.Node) ?Flow {
    const storage: *const Storage = @ptrCast(@alignCast(index));

    if (storage.flow.len == 0 or !ast.sameStorage(node, storage.root)) return null;

    return .{
        .base = @ptrCast(storage.root),
        .facts = storage.flow,
        .unit_firsts = storage.unit_firsts,
        .unit_counts = storage.unit_counts,
        .step_rows = storage.step_rows,
        .events = storage.events,
        .parallel_tasks = storage.parallel_tasks,
        .capacity = storage.capacity,
    };
}

pub fn forNode(index: *const Index, node: *const ast.Node) ?[]const Entry {
    const storage: *const Storage = @ptrCast(@alignCast(index));

    return if (ast.sameStorage(node, storage.root)) storage.entries else null;
}

pub const GraphReferences = struct { entries: []const Entry, count: usize };

pub fn graphForNode(index: *const Index, node: *const ast.Node) ?GraphReferences {
    const storage: *const Storage = @ptrCast(@alignCast(index));

    if (!ast.sameStorage(node, storage.root)) return null;

    return .{ .entries = storage.entries, .count = storage.graph_references };
}

pub const Sequence = struct { missing: ?*const ast.Node };

pub fn sequenceForNode(index: *const Index, node: *const ast.Node) ?Sequence {
    const storage: *const Storage = @ptrCast(@alignCast(index));

    return if (ast.sameStorage(node, storage.root)) .{ .missing = storage.missing_input } else null;
}

pub fn root(index: *const Index) *const ast.Node {
    const storage: *const Storage = @ptrCast(@alignCast(index));

    return storage.root;
}

pub fn sourceExtent(index: *const Index, node: *const ast.Node) ?usize {
    const storage: *const Storage = @ptrCast(@alignCast(index));

    return if (ast.sameStorage(node, storage.root)) storage.source_extent else null;
}

pub const Positions = struct {
    attributes: []const ast.Attribute,
    pub fn attributeAt(self: Positions, offset: usize) ?*const ast.Attribute {
        const end = std.sort.upperBound(ast.Attribute, self.attributes, offset, struct {
            fn compare(value: usize, attribute: ast.Attribute) std.math.Order {
                return std.math.order(value, attribute.value_location.offset);
            }
        }.compare);

        if (end == 0) return null;

        const attribute = &self.attributes[end - 1];

        if (offset - attribute.value_location.offset <= attribute.raw_value.?.len) return attribute;

        return null;
    }
};

pub fn positionsForNode(index: *const Index, node: *const ast.Node) ?Positions {
    const storage: *const Storage = @ptrCast(@alignCast(index));

    return if (ast.sameStorage(node, storage.root)) .{ .attributes = storage.attributes } else null;
}

// The XML parser admits at most 256 nested elements.
const xml_nesting_limit = 256;

pub fn build(comptime scan: anytype, allocator: std.mem.Allocator, temporary: std.mem.Allocator, source: []const u8, input: anytype, slots: []const u64, nodes: []const ast.Node, attributes: []const ast.Attribute, value_extent: usize) std.mem.Allocator.Error!*const Index {
    const Parameter = @typeInfo(@TypeOf(scan)).@"fn".param_types[1].?;
    const Input = if (@typeInfo(Parameter) == .pointer) std.meta.Child(Parameter) else Parameter;
    var storage: [xml_nesting_limit]u64 = undefined;
    const parents: []u64 = &storage;
    const project_flow = nodes[0].children.len != 0 and std.mem.eql(u8, nodes[0].name, "Module");
    const count = if (project_flow) nodes.len else 0;

    if (count > std.math.maxInt(u32)) return error.OutOfMemory;

    const column_words = std.math.mul(usize, count, 4 * @sizeOf(u32) / @sizeOf(u64)) catch return error.OutOfMemory;
    const event_capacity = std.math.mul(usize, count, 2) catch return error.OutOfMemory;
    const length = std.math.add(usize, column_words, event_capacity) catch return error.OutOfMemory;
    const data = try allocator.alloc(u64, length);
    const flow = std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(data[0..column_words]));
    const facts = flow[0..count];
    const unit_firsts = flow[count..][0..count];
    const unit_counts = flow[2 * count ..][0..count];
    const step_rows = flow[3 * count ..];
    const events = data[column_words..];

    const scan_input: Input = .{
        .source = source,
        .nodes = input.tree.nodes,
        .attributes = input.tree.attributes,
        .root = input.control.result,
        .parents = @ptrCast(&parents),
        .slots = slots,
        .facts = @ptrCast(&facts),
        .unit_firsts = @ptrCast(&unit_firsts),
        .unit_counts = @ptrCast(&unit_counts),
        .step_rows = @ptrCast(&step_rows),
        .events = @ptrCast(&events),
        .project_flow = project_flow,
    };

    const result = scan(temporary, if (@typeInfo(Parameter) == .pointer) &scan_input else scan_input) catch |err| switch (err) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    const event_count: usize = @intCast(result.events);

    _ = allocator.resize(data, column_words + event_count);

    const rows = result.references;
    const entries = try allocator.alloc(Entry, rows.len);

    for (rows, entries) |row, *entry| entry.* = .{
        .node = &nodes[@intCast(slots[@intCast(row.node)])],
        .attribute = if (row.attribute) |index| &attributes[@intCast(index)] else null,
        .target = @fromBackingInt(@intCast(@backingInt(row.target))),
        .role = @fromBackingInt(@intCast(@backingInt(row.role))),
        .package_allowed = row.package_allowed,
        .graph = row.graph,
    };

    const index = try allocator.create(Storage);

    index.* = .{
        .root = &nodes[0],
        .entries = entries,
        .graph_references = @intCast(result.graph_references),
        .missing_input = if (result.missing_input) |row| &nodes[@intCast(slots[@intCast(row)])] else null,
        .attributes = attributes,
        .flow = @ptrCast(facts),
        .unit_firsts = unit_firsts,
        .unit_counts = unit_counts,
        .step_rows = step_rows,
        .events = @ptrCast(events[0..event_count]),
        .parallel_tasks = @intCast(result.parallel_tasks),
        .capacity = .{
            .steps = std.math.cast(u32, result.steps) orelse return error.OutOfMemory,
            .calls = std.math.cast(u32, result.calls) orelse return error.OutOfMemory,
            .results = std.math.cast(u32, result.results) orelse return error.OutOfMemory,
            .tasks = std.math.cast(u32, result.tasks) orelse return error.OutOfMemory,
            .groups = std.math.cast(u32, result.groups) orelse return error.OutOfMemory,
            .selections = std.math.cast(u32, result.selections) orelse return error.OutOfMemory,
        },
        .source_extent = @max(value_extent, @as(usize, @intCast(result.source_extent))),
    };

    return @ptrCast(index);
}
