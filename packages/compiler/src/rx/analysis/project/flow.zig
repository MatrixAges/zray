const std = @import("std");
const rx = @import("rx");
const generated = @import("rx_options").generated_graph;
const rule = if (generated) @import("generated_rx_flow_run") else void;

pub const Kind = if (generated) @FieldType(std.meta.Child(rule.Output), "kind") else enum(u8) {
    Call,
    Result,
    Task,
    Parallel,
    Selection,
    ParallelTask,
};

pub const Unit = rx.IndexedFlow.Unit;

pub const Case = struct {
    pub const Label = struct {
        pub const Kind = enum(u8) { Case, Affirmative, Default };

        kind: @This().Kind,
        source: ?*const rx.ast.Attribute = null,
        pub fn attribute(self: Label) ?rx.ast.Attribute {
            return switch (self.kind) {
                .Case => self.source.?.*,
                .Affirmative => .{
                    .name = "value",
                    .value = "true",
                    .kind = .expression,
                    .location = self.source.?.location,
                    .value_location = self.source.?.value_location,
                },
                .Default => null,
            };
        }
    };
    label: Label,
    body: Unit,
    /// Written by inference before the plan is passed to lowering.
    truth: ?bool = null,
};

pub const Task = struct {
    id: ?usize = null,
    node: *const rx.ast.Node,
    body: Unit,
    output: ?rx.ast.Attribute = null,
};

const Selection = struct { subject: *const rx.ast.Attribute, cases: []Case };
const Row = struct { kind: Kind, item: u32 };
const Rows = std.MultiArrayList(Row);

pub const Operation = union(Kind) {
    Call: usize,
    Result: rx.ast.Attribute,
    Task: Task,
    Parallel: Unit,
    Selection: Selection,
    ParallelTask: Task,
};

pub const Plan = struct {
    root: Unit = .{},
    kinds: []const Kind = &.{},
    items: []const u32 = &.{},
    results: []const rx.ast.Attribute = &.{},
    tasks: []const Task = &.{},
    groups: []const Unit = &.{},
    selections: []const Selection = &.{},
};

pub const Builder = struct {
    rows: Rows = .empty,
    results: std.ArrayList(rx.ast.Attribute) = .empty,
    tasks: std.ArrayList(Task) = .empty,
    groups: std.ArrayList(Unit) = .empty,
    selections: std.ArrayList(Selection) = .empty,
    pub fn init(allocator: std.mem.Allocator, capacity: @FieldType(rx.IndexedFlow, "capacity")) std.mem.Allocator.Error!Builder {
        var builder: Builder = .{};

        try builder.rows.setCapacity(allocator, capacity.steps);

        errdefer builder.rows.deinit(allocator);

        try builder.results.ensureTotalCapacityPrecise(allocator, capacity.results);

        errdefer builder.results.deinit(allocator);

        try builder.tasks.ensureTotalCapacityPrecise(allocator, capacity.tasks);

        errdefer builder.tasks.deinit(allocator);

        try builder.groups.ensureTotalCapacityPrecise(allocator, capacity.groups);

        errdefer builder.groups.deinit(allocator);

        try builder.selections.ensureTotalCapacityPrecise(allocator, capacity.selections);

        builder.rows.len = capacity.steps;
        builder.results.items.len = capacity.results;
        builder.tasks.items.len = capacity.tasks;
        builder.groups.items.len = capacity.groups;
        builder.selections.items.len = capacity.selections;

        return builder;
    }
    pub fn reserve(self: *Builder, allocator: std.mem.Allocator, capacity: usize) std.mem.Allocator.Error!u32 {
        const first = try index(self.rows.len);
        const count = try index(capacity);
        const end = std.math.add(u32, first, count) catch return error.OutOfMemory;

        try self.rows.resize(allocator, end);

        return first;
    }
    pub fn write(self: *Builder, allocator: std.mem.Allocator, row: u32, operation: Operation) std.mem.Allocator.Error!void {
        const item = switch (operation) {
            .Call => |call| try index(call),
            .Result => |value| try append(allocator, &self.results, value),
            .Task, .ParallelTask => |task| try append(allocator, &self.tasks, task),
            .Parallel => |group| try append(allocator, &self.groups, group),
            .Selection => |selection| try append(allocator, &self.selections, selection),
        };

        self.rows.set(row, .{ .kind = std.meta.activeTag(operation), .item = item });
    }

    pub fn finish(self: *const Builder, root: Unit) Plan {
        const rows = self.rows.slice();

        return .{
            .root = root,
            .kinds = rows.items(.kind),
            .items = rows.items(.item),
            .results = self.results.items,
            .tasks = self.tasks.items,
            .groups = self.groups.items,
            .selections = self.selections.items,
        };
    }
};

fn append(allocator: std.mem.Allocator, list: anytype, value: anytype) std.mem.Allocator.Error!u32 {
    const item = try index(list.items.len);

    try list.append(allocator, value);

    return item;
}

fn index(value: usize) std.mem.Allocator.Error!u32 {
    return std.math.cast(u32, value) orelse error.OutOfMemory;
}

pub const Exits = struct {
    returns: bool = false,
    terminates: bool = false,
    pub const returned: Exits = .{ .returns = true, .terminates = true };

    pub fn advance(self: *Exits, exits: Exits) void {
        self.returns = self.returns or exits.returns;
        self.terminates = exits.terminates;
    }
};

pub const Sequence = struct {
    unit: Unit,
    exits: Exits = .{},
};

pub const BranchExits = struct {
    has_default: bool = false,
    any_return: bool = false,
    all_terminate: bool = true,
    pub fn add(self: *BranchExits, default: bool, exits: Exits) void {
        self.has_default = self.has_default or default;
        self.any_return = self.any_return or exits.returns;
        self.all_terminate = self.all_terminate and exits.terminates;
    }

    pub fn finish(self: BranchExits) Exits {
        return .{ .returns = self.any_return, .terminates = self.has_default and self.all_terminate };
    }
};
