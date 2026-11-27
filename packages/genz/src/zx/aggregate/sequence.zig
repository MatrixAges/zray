const std = @import("std");
const zx = @import("zx");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const aggregate = @import("../aggregate.zig");
const publication = @import("../construction/publication.zig");
const generated = @import("genz_options").generated_analysis;
const Sequence = @import("../../node/blocks.zig").Sequence;

const Frame = struct {
    lowering: *Lower,
    body: *Sequence,
    type_id: ir.TypeId,
    fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn lower(self: *Lower, id: ir.ExprId, value: ir.ExpressionRow, items: []const ir.ExprId, layout: bool) Lower.Error!node.ExpressionId {
    if (!generated) return seedLower(self, id, value, items, layout);

    if (value.value == .list) {
        if (try @import("../static_list.zig").lower(self, value, items)) |literal| {
            return @import("../state_value/list.zig").wrap(self, value.type_id, literal, false);
        }
    }

    var body = self.builder.statementSequence(self.workspace);

    defer body.deinit();

    var frame: Frame = .{ .lowering = self, .body = &body, .type_id = value.type_id };
    var origin: publication.OriginBuffer = undefined;
    const execute = @import("generated_lower_sequence_elements");
    const Input = std.meta.Child(execute.Input);
    const selected = value.value == .tuple and self.state_active and self.state_plan.selected[@backingInt(value.type_id)];

    const input: Input = .{
        .frame = @ptrCast(self),
        .writer = @ptrCast(self),
        .origin = @ptrCast(&origin),
        .sequence = @ptrCast(&body),
        .batch = @ptrCast(&frame),
        .kind = zx.columns.view(@FieldType(Input, "kind"), self.program.expressions.kinds[@backingInt(id)]),
        .layout = layout,
        .state_active = self.state_active,
        .selected = selected,
        .items = @ptrCast(items),
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [512]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const output = execute.executeIn(memory.allocator(), &input) catch |err| return publication.failure(err);

    const result = switch (output.result) {
        .Tuple => try self.construct(value.type_id, @fromBackingInt(output.tuple.?)),
        .LayoutTuple => try @import("../state_value/origin.zig").tuple(self, value.type_id, @fromBackingInt(output.tuple.?)),
        .List, .Template => items: {
            const expressions = try self.allocator.alloc(node.ExpressionId, output.expressions.len);

            for (output.expressions, 0..) |item_id, idx| expressions[idx] = @fromBackingInt(item_id);

            break :items switch (output.result) {
                .List => try @import("../state_value/list.zig").wrap(self, value.type_id, try @import("list.zig").literal(self, value.type_id, expressions), false),
                .Template => try @import("../templates.zig").lower(self, items, expressions),
                else => unreachable,
            };
        },
    };

    return aggregate.finish(self, &body, result);
}

pub fn publishSequenceElement(handle: *anyopaque, item: u32, bound: u32, is_list: bool) Lower.Error!u32 {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const expression: node.ExpressionId = @fromBackingInt(bound);

    return @backingInt(if (is_list)
        try @import("../state_value/elements.zig").write(self, frame.body, frame.type_id, expression)
    else
        try @import("../state_value/conversion.zig").convert(self, frame.body, self.program.expression(@fromBackingInt(item)).type_id, expression, .pointer));
}

fn seedLower(self: *Lower, id: ir.ExprId, value: ir.ExpressionRow, items: []const ir.ExprId, layout: bool) Lower.Error!node.ExpressionId {
    _ = id;

    const selected = value.value == .tuple and self.state_active and self.state_plan.selected[@backingInt(value.type_id)];

    if (value.value == .list) {
        if (try @import("../static_list.zig").lower(self, value, items)) |literal| {
            return @import("../state_value/list.zig").wrap(self, value.type_id, literal, false);
        }
    }

    var body: std.ArrayList(node.Statement) = .empty;
    const expressions = try self.allocator.alloc(node.ExpressionId, items.len);

    for (items, 0..) |item, index| {
        const bound = try aggregate.bind(self, &body, try self.expr(item));

        expressions[index] = switch (value.value) {
            .list => try @import("../state_value/elements.zig").write(self, &body, value.type_id, bound),
            .tuple => if (self.state_active and !selected)
                try @import("../state_value/conversion.zig").convert(self, &body, self.program.expression(item).type_id, bound, .pointer)
            else
                bound,
            .template => bound,
            else => unreachable,
        };
    }

    const result = switch (value.value) {
        .tuple => tuple: {
            const tuple = try self.builder.expression(.{ .tuple = expressions });

            break :tuple if (layout) try @import("../state_value/origin.zig").tuple(self, value.type_id, tuple) else try self.construct(value.type_id, tuple);
        },
        .list => try @import("../state_value/list.zig").wrap(self, value.type_id, try @import("list.zig").literal(self, value.type_id, expressions), false),
        .template => try @import("../templates.zig").lower(self, items, expressions),
        else => unreachable,
    };

    return aggregate.finish(self, &body, result);
}
