const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../../node.zig");
const Lower = @import("../../lower.zig");
const aggregate = @import("../../aggregate.zig");
const list = @import("../../state_value/list.zig");
const emit = @import("../emit.zig");
const path = @import("path.zig");
const rules = @import("rules.zig");
const seed = @import("seed.zig");
const generated = @import("genz_options").generated_analysis;
const entry = @import("generated_projection_read");
const result_entry = @import("generated_projection_result");
const Result = if (generated) @typeInfo(@typeInfo(@TypeOf(result_entry.executeValue)).@"fn".return_type.?).error_union.payload else seed.Result;

pub fn field(self: *Lower, id: ir.TypeId, item: ir.Projection, iteration: bool) Lower.Error!node.ExpressionId {
    return member(self, id, item, false, iteration);
}

pub fn tuple(self: *Lower, id: ir.TypeId, item: ir.Projection, iteration: bool) Lower.Error!node.ExpressionId {
    if (try @import("../../collections.zig").projection(self, item.target, item.index)) |selected| return selected;

    return member(self, id, item, true, iteration);
}

pub fn index(self: *Lower, id: ir.TypeId, target: ir.ExprId, key: ir.ExprId, iteration: bool) Lower.Error!node.ExpressionId {
    if (iteration) {
        const items = try self.field(try self.expr(target), "items");

        return @import("../../intrinsics.zig").index(self, items, try self.expr(key));
    }

    const raw = try path.nested(self, target);
    const source = raw orelse try list.expression(self, target);
    const indexed = try @import("../../intrinsics.zig").index(self, source, try self.expr(key));

    return resolvedIndex(self, id, target, indexed, raw != null);
}

pub fn length(self: *Lower, child: ir.ExprId, type_expr: node.ExpressionId, iteration: bool) Lower.Error!node.ExpressionId {
    if (iteration) return emit.length(self, try self.expr(child), type_expr, true);

    const raw = try path.nested(self, child);
    const source = raw orelse try list.expression(self, child);

    return emit.length(self, source, type_expr, false);
}

fn member(self: *Lower, id: ir.TypeId, item: ir.Projection, tuple_member: bool, iteration: bool) Lower.Error!node.ExpressionId {
    const target_type = typeOf(self, item.target);
    const raw = if (!iteration and rules.raw(self, target_type, false)) try path.lower(self, item.target) else null;
    const source = if (iteration) try self.expr(item.target) else raw orelse try path.anchor(self, item.target);

    if (!generated) {
        const name = if (tuple_member)
            try std.fmt.allocPrint(self.allocator, "{d}", .{item.index})
        else
            self.program.typeOf(target_type).object.at(item.index).name;

        const field_value = try self.field(source, name);
        const value = if (seed.borrowed(self, item.target, name)) try emit.dereference(self, field_value) else field_value;

        return finish(self, id, target_type, value, seed.result(self, id, target_type, raw != null, true));
    }

    return resolvedMember(self, id, target_type, item, source, raw != null, tuple_member, iteration);
}

pub fn resolvedIndex(self: *Lower, id: ir.TypeId, target: ir.ExprId, value: node.ExpressionId, raw: bool) Lower.Error!node.ExpressionId {
    const target_type = typeOf(self, target);
    const result = indexResult(self, id, target_type, raw);

    return finish(self, id, target_type, value, result);
}

pub fn resolvedMember(self: *Lower, id: ir.TypeId, target_type: ir.TypeId, item: ir.Projection, source: node.ExpressionId, raw: bool, tuple_member: bool, iteration: bool) Lower.Error!node.ExpressionId {
    const read = try emitMember(self, id, target_type, item, source, raw, tuple_member, iteration);

    return finish(self, id, target_type, read.value, read.result);
}

fn finish(self: *Lower, id: ir.TypeId, target_type: ir.TypeId, value: node.ExpressionId, result: Result) Lower.Error!node.ExpressionId {
    switch (result) {
        .Direct => return value,
        .Borrowed => return list.borrowed(self, id, value),
        .Value, .Element => {},
    }

    var body: std.ArrayList(node.Statement) = .empty;

    const converted = switch (result) {
        .Value => try @import("../../state_value/conversion.zig").convert(self, &body, id, try aggregate.bind(self, &body, value), .value),
        .Element => try @import("../../state_value/elements.zig").read(self, &body, target_type, value),
        else => unreachable,
    };

    return aggregate.finish(self, &body, converted);
}

const MemberResult = struct { value: node.ExpressionId, result: Result };
const Request = struct { id: ir.TypeId, target_type: ir.TypeId, raw: bool, field: bool, iteration: bool = false };

fn emitMember(self: *Lower, id: ir.TypeId, target_type: ir.TypeId, item: ir.Projection, source: node.ExpressionId, raw: bool, tuple_member: bool, iteration: bool) Lower.Error!MemberResult {
    const Input = std.meta.Child(entry.Input);
    const Value = std.meta.Child(@FieldType(Input, "value"));
    const Borrow = std.meta.Child(std.meta.Child(@FieldType(Input, "projection")));
    const storage = rules.storage(std.meta.Child(@FieldType(Value, "storage")), self);

    const value = facts(Value, self, &storage, .{
        .id = id,
        .target_type = target_type,
        .raw = raw,
        .field = true,
        .iteration = iteration,
    });

    var borrowed: Borrow = undefined;

    const projection = if (self.loop_fields) |context| selected: {
        if (iteration or tuple_member) break :selected null;

        borrowed = .{
            .states = context.states,
            .borrowed = context.borrowed,
            .target = @backingInt(item.target),
            .member = item.index,
        };

        break :selected &borrowed;
    } else null;

    const member_view: std.meta.Child(@FieldType(Input, "member")) = .{
        .names = self.program.types.field_names,
        .first = self.program.types.first[@backingInt(target_type)],
        .position = item.index,
        .tuple = tuple_member,
    };

    const input: Input = .{
        .value = &value,
        .member = &member_view,
        .source = @backingInt(source),
        .base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .projection = projection,
    };

    var buffer: [1024]u8 = undefined;
    var memory = std.heap.FixedBufferAllocator.init(&buffer);
    const output = zx.columns.invoke(entry.executeValue, memory.allocator(), &input) catch |err| return failure(err);

    if (!output.valid) return error.OutOfMemory;

    var rows = zx.columns.view(std.meta.Child(@FieldType(std.meta.Child(entry.Output), "rows")), output.rows);
    const owned_name = if (tuple_member) try self.allocator.dupe(u8, rows.field_name[0]) else rows.field_name[0];
    const names = [_][]const u8{owned_name};

    rows.field_name = &names;

    @import("../../../node/import_rows.zig").appendBorrowed(self.allocator, &self.builder.nodes.expressions, &rows) catch |err| return failure(err);

    return .{ .value = @fromBackingInt(output.root), .result = @fromBackingInt(@backingInt(output.result)) };
}

fn indexResult(self: *const Lower, id: ir.TypeId, target_type: ir.TypeId, raw: bool) Result {
    if (!generated) return seed.result(self, id, target_type, raw, false);

    const Input = std.meta.Child(result_entry.Input);
    const storage = rules.storage(std.meta.Child(@FieldType(Input, "storage")), self);
    const input = facts(Input, self, &storage, .{ .id = id, .target_type = target_type, .raw = raw, .field = false });
    var memory = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(result_entry.executeValue, memory.allocator(), &input) catch unreachable;
}

fn facts(comptime Value: type, self: *const Lower, storage: @FieldType(Value, "storage"), request: Request) Value {
    return .{
        .storage = storage,
        .type_id = @backingInt(request.id),
        .target = @fromBackingInt(@intCast(@backingInt(self.state_plan.queries[@backingInt(request.target_type)]))),
        .result = @fromBackingInt(@intCast(@backingInt(self.state_plan.queries[@backingInt(request.id)]))),
        .active = self.state_active and !request.iteration,
        .raw = request.raw,
        .field = request.field,
    };
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow => error.OutOfMemory,
        else => unreachable,
    };
}

fn typeOf(self: *const Lower, id: ir.ExprId) ir.TypeId {
    return @fromBackingInt(self.program.expressions.types[@backingInt(id)]);
}
