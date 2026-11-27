const std = @import("std");
const zx = @import("zx");
const ast = @import("dsl").ast;
const layout = @import("../../syntax/tree/layout.zig").bind;
const Entry = @import("frontend").xml_references.Entry;
const rule = @import("generated_rx_ast_reference_next");
const select_rule = @import("generated_rx_ast_reference_select");
const Input = std.meta.Child(rule.Input);

pub const Cursor = struct {
    root: ?[1][]const u8 = null,
    pending: std.ArrayList([]const u8) = .empty,
    pub fn reset(self: *Cursor, root: *const ast.Node) void {
        std.debug.assert(self.pending.items.len == 0);

        self.root = .{std.mem.asBytes(root)};
    }

    pub fn deinit(self: *Cursor, allocator: std.mem.Allocator) void {
        self.pending.deinit(allocator);
    }

    pub fn borrow(self: *const Cursor, comptime Wire: type, _: *const std.mem.Allocator) Wire {
        const geometry = comptime layout(std.meta.Child(@FieldType(Wire, "layout")));

        return .{
            .pending = if (self.root) |*root| root else self.pending.items,
            .layout = &geometry,
        };
    }
    fn retainPending(self: *Cursor, allocator: std.mem.Allocator, pending: []const []const u8) std.mem.Allocator.Error!void {
        if (pending.ptr == self.pending.items.ptr) {
            self.pending.shrinkRetainingCapacity(pending.len);
        } else {
            try self.pending.ensureTotalCapacity(allocator, pending.len);

            self.pending.clearRetainingCapacity();
            self.pending.appendSliceAssumeCapacity(pending);
        }

        self.root = null;
    }
    pub fn seek(self: *Cursor, allocator: std.mem.Allocator, graph_only: bool, skip: u64) std.mem.Allocator.Error!?Entry {
        var buffer: [1024]u8 = undefined;
        var first = std.heap.BufferFirstAllocator.init(&buffer, allocator);
        var arena = std.heap.ArenaAllocator.init(first.allocator());

        defer arena.deinit();

        const request: Input = .{
            .cursor = &self.borrow(std.meta.Child(@FieldType(Input, "cursor")), &allocator),
            .graph_only = graph_only,
            .skip = skip,
        };

        const step = zx.columns.invoke(rule.executeValue, arena.allocator(), &request) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory, error.Overflow => return error.OutOfMemory,
            else => unreachable,
        };

        try self.retainPending(allocator, step.pending);

        return if (step.reference) |item| fromWire(item) else null;
    }
    pub fn batch(self: *Cursor, allocator: std.mem.Allocator, references_arg: [][]const u8, packages_arg: []u8) std.mem.Allocator.Error!?usize {
        var buffer: [4096]u8 = undefined;
        var first = std.heap.BufferFirstAllocator.init(&buffer, allocator);
        var arena = std.heap.ArenaAllocator.init(first.allocator());

        defer arena.deinit();

        const entry = @import("generated_rx_ast_reference_batch");
        const Request = std.meta.Child(entry.Input);

        const result = entry.executeValue(arena.allocator(), &.{
            .cursor = &self.borrow(std.meta.Child(@FieldType(Request, "cursor")), &allocator),
            .capacity = references_arg.len,
        }) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory, error.Overflow => return error.OutOfMemory,
            else => unreachable,
        };

        try self.retainPending(allocator, result.pending);
        if (result.references.len == 0) return null;

        @memcpy(references_arg[0..result.references.len], result.references);
        @memcpy(packages_arg[0..result.packages.len], result.packages);

        return result.references.len;
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
