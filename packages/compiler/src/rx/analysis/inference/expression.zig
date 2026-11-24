const std = @import("std");
const zx = @import("zx");
const syntax = zx.syntax.borrow;
const rx = @import("rx");
const frontend = @import("frontend");
const paths = frontend.binding_path;
const Graph = @import("types.zig");
const Scope = @import("scope.zig");
const condition = @import("../condition.zig");
const operators = @import("operators.zig");
const composition = @import("expression/composition.zig");
const Self = @This();
const path_buffer_size = 128;

graph: *Graph,
scope: std.mem.Allocator,
aliases: frontend.expressions.BindingColumns = .{},
input: Graph.Id,
input_used: bool = false,
bindings: Scope.Storage = .empty,
nonnull: std.ArrayList([]const u8) = .empty,
attribute: rx.ast.Attribute,
span_offset: usize = 0,
pub fn infer(self: *Self, expression: anytype, expected: ?Graph.Id) zx.Error!Graph.Id {
    return self.inferValue(expression, expected, true);
}

pub fn declared(self: *Self, expression: anytype) zx.Error!Graph.Id {
    return self.inferValue(expression, null, false);
}

fn inferValue(self: *Self, expression: anytype, expected: ?Graph.Id, comptime refine: bool) zx.Error!Graph.Id {
    const node = syntax.value(expression);
    const span = self.sourceSpan(expression.span);
    const reference = try self.resolveReference(expression, node, span, refine);
    const base = reference.value orelse try self.inferNode(node, expression, span, expected, try self.payload(expected), reference.implicit_input);
    const value = try self.refined(reference.refined, base, span);

    if (reference.value != null) try self.graph.requireValue(value, span);

    if (expected) |target| {
        try self.graph.expect(value, target, span);

        return target;
    }

    return value;
}

fn resolveReference(self: *Self, expression: anytype, node: anytype, span: zx.Span, comptime refine: bool) zx.Error!Scope.Reference {
    const facts: []const []const u8 = if (refine) self.nonnull.items else &.{};
    const rows = self.bindings.slice();

    if (node == .identifier) return Scope.read(self.graph, rows, facts, node.identifier.text, true, span);
    if (node != .field or (rows.len == 0 and facts.len == 0)) return .{};

    var buffer: [path_buffer_size]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, self.graph.scratch);
    const allocator = scratch.allocator();
    const path = (try paths.view(allocator, expression)) orelse return .{};

    defer path.release(allocator);

    return Scope.read(self.graph, rows, facts, path.text, false, span);
}

fn inferNode(self: *Self, node: anytype, expression: anytype, span: zx.Span, expected: ?Graph.Id, hint: ?Graph.Id, implicit_input: bool) zx.Error!Graph.Id {
    return switch (node) {
        .identifier => block: {
            if (!implicit_input) return self.graph.reporter.fail(.name, span, "flow value is not defined in this scope");

            self.input_used = true;

            break :block self.input;
        },
        .field => |field| (try self.enumMember(field.target, field.name, span)) orelse try self.graph.field(try self.infer(field.target, null), field.name.text, span),
        .number => |text| try self.graph.number(text, false, span),
        .boolean => try self.graph.scalar(.bool, span),
        .string => try self.graph.scalar(.string, span),
        .template => |parts| try composition.template(self, parts, span),
        .null_value => try self.graph.addContainers(null, .optional, 1, span),
        .object => |fields| try @import("objects.zig").infer(self, fields, hint, span),
        .list => |items| try @import("sequences.zig").infer(self, items, hint, span),
        .index => |item| try @import("index.zig").infer(self, item, span),
        .unary => |unary| try operators.inferUnary(self, unary, span),
        .binary => |binary| try operators.inferBinary(self, binary, hint, span),
        .conditional => |branch| try operators.inferConditional(self, branch, expected, span),
        .match_expr => |selection| try composition.matching(self, selection, expected, span),
        .call => |call| try @import("selection.zig").infer(self, expression, call, span),
        .pipeline, .lambda, .state_block, .capture, .task, .await_task, .cancel_task => return self.graph.reporter.fail(.unsupported, span, @import("../value_rules.zig").message),
    };
}

pub fn payload(self: *Self, expected: ?Graph.Id) zx.Error!?Graph.Id {
    return @import("optional.zig").hint(self.graph, expected orelse return null);
}

pub fn sourceSpan(self: *const Self, value: zx.Span) zx.Span {
    const base = self.attribute.value_location.offset;
    const start = rx.attributeByteOffset(self.attribute, value.start, false) orelse base;
    const end = if (value.start == value.end) start else rx.attributeByteOffset(self.attribute, value.end, true) orelse base;

    return .{ .start = self.span_offset + start, .end = self.span_offset + end };
}

pub fn conditionScope(self: *Self) condition.Scope {
    return .{
        .allocator = self.scope,
        .bindings = self.bindings.items(.name),
        .implicit_input = true,
        .facts = &self.nonnull,
    };
}

fn refined(self: *Self, nonnull: bool, value: Graph.Id, span: zx.Span) zx.Error!Graph.Id {
    if (nonnull) return @import("non_null.zig").read(self.graph, value, span);

    return value;
}

fn enumMember(self: *Self, owner: anytype, name: zx.ast.Name, span: zx.Span) zx.Error!?Graph.Id {
    if (self.aliases.names.len == 0) return null;

    const value = syntax.value(owner);

    if (value != .field or syntax.value(value.field.target) != .identifier) return null;

    var buffer: [path_buffer_size]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, self.graph.scratch);
    const allocator = scratch.allocator();
    const path = (try paths.view(allocator, owner)).?;

    defer path.release(allocator);

    const match = self.findEnumMember(path, name.text);
    const type_id = match.type_id orelse return null;

    if (!match.member) return self.graph.reporter.fail(.name, self.sourceSpan(name.span), "unknown enum member");

    return try self.graph.known(type_id, span);
}

fn findEnumMember(self: *const Self, owner: paths.Path, name: []const u8) struct { type_id: ?zx.ir.TypeId = null, member: bool = false } {
    const aliases = self.aliases;
    const active = self.bindings.items(.name);

    if (comptime !@import("rx_options").generated_graph) {
        if (Scope.rooted(active, owner, true)) return .{};

        for (aliases.names, aliases.types) |alias, type_id| {
            if (!std.mem.eql(u8, owner.text, alias)) continue;

            const target = self.graph.types.get(type_id);

            if (target != .enumeration) return .{};

            for (target.enumeration.members) |candidate| {
                if (std.mem.eql(u8, candidate, name)) return .{ .type_id = type_id, .member = true };
            }

            return .{ .type_id = type_id };
        }

        return .{};
    }

    const types = &self.graph.types.items;
    const generated = @import("generated_rx_enum_member");

    const input: std.meta.Child(generated.Input) = .{
        .aliases = &.{ .names = aliases.names, .ids = @ptrCast(aliases.types) },
        .types = &.{ .kinds = types.kinds.items, .first = types.first.items, .second = types.second.items, .names = types.names.items },
        .bindings = active,
        .owner = owner.text,
        .name = name,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const result = zx.columns.invoke(generated.executeValue, empty.allocator(), &input) catch unreachable;

    return .{ .type_id = if (result.type_id) |id| @fromBackingInt(id) else null, .member = result.member };
}
