const std = @import("std");
const ast = @import("dsl").ast;
const Entry = @import("frontend").xml_references.Entry;
const rule = @import("generated_rx_ast_reference_next");
const select_rule = @import("generated_rx_ast_reference_select");
const Input = @typeInfo(@TypeOf(rule.executeValue)).@"fn".param_types[1].?;

pub const Cursor = struct {
    pending: []const u8 = &.{},
    ancestors: std.ArrayList([]const u8) = .empty,
    pub fn reset(self: *Cursor, root: *const ast.Node) void {
        std.debug.assert(self.ancestors.items.len == 0);

        self.pending = std.mem.asBytes(root);
    }

    pub fn deinit(self: *Cursor, allocator: std.mem.Allocator) void {
        self.ancestors.deinit(allocator);
    }

    pub fn borrow(self: *Cursor, comptime Wire: type, allocator: *const std.mem.Allocator) Wire {
        const geometry = comptime layout(std.meta.Child(@FieldType(Wire, "layout")));

        return .{
            .pending = self.pending,
            .ancestors = @ptrCast(&self.ancestors),
            .allocator = @ptrCast(allocator),
            .layout = &geometry,
        };
    }
    pub fn seek(self: *Cursor, allocator: std.mem.Allocator, graph_only: bool, skip: u64) std.mem.Allocator.Error!?Entry {
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        const request: Input = .{
            .cursor = self.borrow(@FieldType(Input, "cursor"), &allocator),
            .graph_only = graph_only,
            .skip = skip,
        };

        const step = rule.executeValue(empty.allocator(), request) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory, error.Overflow => return error.OutOfMemory,
            else => unreachable,
        };

        self.pending = step.pending;

        return if (step.reference) |item| fromWire(item) else null;
    }
    pub fn batch(self: *Cursor, allocator: std.mem.Allocator, references: [][]const u8, packages: []u8) std.mem.Allocator.Error!?usize {
        const entry = @import("generated_rx_ast_reference_batch");
        const Request = std.meta.Child(entry.Input);
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        const result = entry.executeValue(empty.allocator(), &.{
            .cursor = &self.borrow(std.meta.Child(@FieldType(Request, "cursor")), &allocator),
            .references = @ptrCast(&references),
            .packages = @ptrCast(&packages),
            .attribute_value = @offsetOf(ast.Attribute, "value"),
            .capacity = references.len,
        }) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory, error.Overflow => return error.OutOfMemory,
            else => unreachable,
        };

        self.pending = result.pending;

        return if (result.count == 0) null else @intCast(result.count);
    }
};

pub fn select(node: *const ast.Node, graph_only: bool) ?Entry {
    const Request = @typeInfo(@TypeOf(select_rule.executeValue)).@"fn".param_types[1].?;
    const geometry = comptime layout(std.meta.Child(@FieldType(Request, "layout")));
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const result = select_rule.executeValue(empty.allocator(), .{
        .node = std.mem.asBytes(node),
        .layout = &geometry,
        .graph_only = graph_only,
    }) catch unreachable;

    return if (result) |item| fromWire(item) else null;
}

fn layout(comptime Layout: type) Layout {
    return .{
        .node_width = @sizeOf(ast.Node),
        .node_name = @offsetOf(ast.Node, "name"),
        .node_children = @offsetOf(ast.Node, "children"),
        .node_attributes = @offsetOf(ast.Node, "attributes"),
        .attribute_width = @sizeOf(ast.Attribute),
        .attribute_name = @offsetOf(ast.Attribute, "name"),
    };
}

pub fn fromWire(item: anytype) Entry {
    const node: *const ast.Node = @ptrCast(@alignCast(item.node.ptr));
    const attribute = item.attribute orelse return .{ .node = node };

    return .{
        .node = node,
        .attribute = @ptrCast(@alignCast(attribute.ptr)),
        .target = @fromBackingInt(@intCast(@backingInt(item.target))),
        .role = @fromBackingInt(@intCast(@backingInt(item.role))),
        .package_allowed = item.package_allowed,
        .graph = item.graph,
    };
}
