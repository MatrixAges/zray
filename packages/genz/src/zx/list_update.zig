const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../node.zig");
const Lower = @import("lower.zig");
const publication = @import("construction/publication.zig");
const Error = Lower.Error;
const Work = @import("collections/branch.zig");
const generated = @import("genz_options").generated_analysis;

pub fn lower(self: *Lower, id: ir.ExprId) Error!node.ExpressionId {
    if (comptime !generated) return @import("list_update_seed.zig").lower(self, id);

    const update = self.program.expression(id).value.list_update;
    const entry = @import("generated_run_list_update");
    const Input = std.meta.Child(entry.Input);
    const Ast = std.meta.Child(@FieldType(Input, "ast"));
    const Elements = std.meta.Child(@FieldType(Ast, "elements"));
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());
    const source_type: ir.TypeId = @fromBackingInt(self.program.expressions.types[@backingInt(update.target)]);
    var body = self.builder.statementSequence(self.workspace);
    const represented = @import("state_value/list.zig").selected(self, source_type);
    const storage = bufferPlan(self, id, update.target, represented);

    defer scratch.deinit();
    defer body.deinit();

    var types: std.meta.Child(@FieldType(Elements, "types")) = undefined;
    const elements = @import("state_value/element_emission.zig").borrowSource(Elements, self, &types);

    const input: Input = .{
        .ast = &.{
            .lower = @ptrCast(self),
            .writer = @ptrCast(self),
            .sequence = @ptrCast(&body),
            .elements = &elements,
        },
        .represented = represented,
        .deferred = storage.deferred,
        .in_place = storage.in_place,
        .transfer = storage.transfer,
        .grow = storage.grow,
        .exact = !self.may_grow,
        .shared = self.shared_types,
        .source_type = @backingInt(source_type),
        .target = @backingInt(update.target),
        .index = @backingInt(update.index),
        .value = @backingInt(update.value),
    };

    var work: Work = .{ .lowering = self, .sequence = &body };
    const view: Work.View = &work.state;
    const host: Work.Host = .{ .work = &work, .store_0 = &view };

    return @fromBackingInt(entry.executeIn(memory.allocator(), &input, host) catch |err| return publication.failure(err));
}

const BufferPlan = struct { deferred: bool, in_place: bool, transfer: bool, grow: bool };

pub fn bufferPlan(self: *const Lower, id: ir.ExprId, target: ir.ExprId, represented: bool) BufferPlan {
    const flags = self.plan.get(id);
    const deferred = represented and self.deferred_lists;

    if (flags.in_place and !deferred) return .{ .deferred = false, .in_place = true, .transfer = false, .grow = false };

    const transfer = @import("state_value/ownership.zig").eligible(self, target, 0);
    // A dynamic literal has its own writable buffer even when carried lists defer their first copy.
    const fresh = transfer and freshBuffer(self, target);

    return .{
        .deferred = deferred and !fresh,
        .in_place = flags.in_place or fresh,
        .transfer = represented and transfer,
        .grow = flags.grow and !fresh,
    };
}

fn freshBuffer(self: *const Lower, target: ir.ExprId) bool {
    if (self.iteration_value != null or self.loop_fields != null) return false;

    var id = target;

    while (!self.cache.contains(id)) {
        const row = self.program.expression(id);

        switch (row.value) {
            .list => |items| return items.len != 0 and !staticList(self, row.type_id, items),
            .field => |field| {
                if (self.cache.contains(field.target)) return false;

                const source = self.program.expression(field.target).value;

                if (source != .object) return false;

                for (0..source.object.fields.len) |index| {
                    const member = source.object.fields.at(index);

                    if (member.index != field.index) continue;

                    id = member.value;

                    break;
                } else return false;
            },
            .tuple_field => |field| {
                if (self.cache.contains(field.target)) return false;

                const source = self.program.expression(field.target).value;

                if (source != .tuple) return false;

                id = source.tuple[field.index];
            },
            else => return false,
        }
    }

    return false;
}

fn staticList(self: *const Lower, type_id: ir.TypeId, items: []const ir.ExprId) bool {
    if (comptime generated) {
        const check = @import("generated_static_list_candidate");
        const Input = std.meta.Child(check.Input);
        const view = @import("../node/view.zig");
        const zx = @import("zx");
        const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(Input, "types")), self.program.types);

        const input: Input = .{
            .types = &types,
            .kinds = zx.columns.slice(@FieldType(Input, "kinds"), self.program.expressions.kinds),
            .type_id = @backingInt(type_id),
            .items = view.slice(@FieldType(Input, "items"), items),
        };

        var memory = std.heap.FixedBufferAllocator.init(&.{});

        return zx.columns.invoke(check.executeValue, memory.allocator(), &input) catch unreachable;
    }

    switch (self.program.typeOf(self.program.typeOf(type_id).list)) {
        .scalar, .enumeration, .error_set => {},
        else => return false,
    }

    for (items) |item| switch (self.program.expression(item).value) {
        .integer, .negative_integer, .float, .string, .boolean, .unit, .enum_value, .error_value => {},
        else => return false,
    };

    return true;
}
