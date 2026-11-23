const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Nodes = @import("../nodes.zig");

const Receiver = struct {
    kind: Nodes.Kind,
    type_kind: u8,
    type_argument: u32,
    restricted: bool,
    name: []const u8,
};

const Members = struct {
    names: []const []const u8,
    values: []const u32,
};

const Route = enum {
    KnownMember,
    Member,
    MissingMember,
    AppendMember,
    ScalarConflict,
    Length,
    RequireList,
    DeferLength,
    InvalidDeclared,
    InvalidInferred,
};

const Plan = struct { route: Route, value: u32 = 0 };
const TypeKind = std.meta.Tag(zx.ir.Type);
const length_name = @import("access.zig").length_name;

pub fn at(graph: *Graph, target: Graph.Id, root: Graph.Id, name: []const u8, span: zx.Span) zx.Error!Graph.Id {
    const index = @backingInt(root);
    const rows = graph.nodes.slice();
    const kind = rows.items(.kind)[index];
    const known = kind == .Known;
    const types = &graph.types.items;
    const type_id = rows.items(.argument)[index];
    const type_kind = if (known) types.kinds.items[type_id] else 0;
    const type_argument = if (known) types.first.items[type_id] else 0;
    const inferred = if (kind == .Object) Graph.Fields.fromValues(@ptrCast(rows.items(.members)[index])) else Graph.Fields{};

    const members: Members = if (known and type_kind == @backingInt(TypeKind.object)) object: {
        const length = types.second.items[type_id];

        break :object .{
            .names = types.field_names.items[type_argument..][0..length],
            .values = types.field_types.items[type_argument..][0..length],
        };
    } else .{ .names = inferred.names(), .values = @ptrCast(inferred.values()) };

    const receiver: Receiver = .{
        .kind = kind,
        .type_kind = type_kind,
        .type_argument = type_argument,
        .restricted = rows.items(.allowed)[index] != null,
        .name = name,
    };

    const plan = decide(&receiver, &members);

    switch (plan.route) {
        .KnownMember => return graph.known(@fromBackingInt(plan.value), span),
        .Member => return @fromBackingInt(plan.value),
        .AppendMember => return append(graph, index, inferred, name, span),
        .MissingMember, .ScalarConflict, .InvalidDeclared, .InvalidInferred => return fail(graph, plan.route, span),
        .Length => return graph.scalar(.u64, span),
        .RequireList => {
            _ = try graph.payload(target, .list, span);

            return graph.scalar(.u64, span);
        },
        .DeferLength => {
            const result = try graph.add(.unknown, span);

            try graph.pending.lengths.append(graph.pending.allocator, .{ .target = target, .value = result, .span = span });

            return result;
        },
    }
}

fn fail(graph: *const Graph, route: anytype, span: zx.Span) zx.Error {
    return graph.reporter.fail(.type_mismatch, span, switch (route) {
        .MissingMember => "the complete input type does not contain this field",
        .ScalarConflict => "object fields conflict with scalar requirements",
        .InvalidDeclared => "field access requires an object",
        .InvalidInferred => "field requirements conflict with the inferred input type",
        else => unreachable,
    });
}

fn append(graph: *Graph, index: usize, fields: Graph.Fields, name: []const u8, span: zx.Span) zx.Error!Graph.Id {
    const result = try graph.add(.unknown, span);
    const retained = try graph.types.allocator.dupe(u8, name);
    const extended = try Graph.Fields.init(graph.allocator, fields.len + 1);

    fields.copyTo(extended);
    extended.set(fields.len, retained, result);
    graph.setShape(index, .{ .object = extended });

    graph.revision += 1;

    return result;
}

fn decide(receiver: *const Receiver, members: *const Members) Plan {
    const declared = receiver.kind == .Known and receiver.type_kind == @backingInt(TypeKind.object);

    if (receiver.kind == .Object or declared) {
        if (!declared and receiver.restricted) return .{ .route = .ScalarConflict };

        for (members.names, members.values) |name, value| {
            if (std.mem.eql(u8, name, receiver.name)) return .{ .route = if (declared) .KnownMember else .Member, .value = value };
        }

        return .{ .route = if (declared) .MissingMember else .AppendMember };
    }

    const length = std.mem.eql(u8, receiver.name, length_name);

    const route: Route = switch (receiver.kind) {
        .Unknown => if (length) .DeferLength else if (receiver.restricted) .ScalarConflict else .AppendMember,
        .Sequence => if (length) .RequireList else .InvalidInferred,
        .List => if (length) .Length else .InvalidInferred,
        .Known => if (length and lengthType(receiver)) .Length else .InvalidDeclared,
        else => .InvalidInferred,
    };

    return .{ .route = route };
}

fn lengthType(receiver: *const Receiver) bool {
    return switch (@as(TypeKind, @fromBackingInt(@intCast(receiver.type_kind)))) {
        .list => true,
        .scalar => receiver.type_argument == @backingInt(zx.ir.Scalar.string),
        else => false,
    };
}
