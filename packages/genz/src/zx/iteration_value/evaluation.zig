const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Context = @import("root.zig");
const Lower = @import("../lower.zig");
const aggregate = @import("../aggregate.zig");
const collections = @import("../collections.zig");
const dispatch = @import("../expressions/dispatch.zig");
const read = @import("../expressions/read.zig");
const Probe = @import("../expression_map.zig").Probe;

pub fn lower(self: *Context, id: ir.ExprId, probe: Probe) Lower.Error!node.ExpressionId {
    const lowering = self.lowering;
    const plan = select(self, id, probe);
    const checked: Probe = .{ .checked = plan.probe.checked, .value = plan.probe.value };

    switch (plan.route) {
        .Argument => return self.argument.?.value,
        .Cached => {
            try self.reads.increment(lowering.allocator, id);

            return @fromBackingInt(plan.value.?);
        },
        .Fallback, .Binary => return lowering.regularWithCache(id, checked),
        .Unpack => return unpack(self, id, try lowering.regularWithCache(id, checked)),
        inline .Reference, .Field, .Unwrap, .TupleField, .Index, .Length, .Some, .None => |route| {
            const action: dispatch.Action = comptime switch (route) {
                .Some => .Wrap,
                .None => .Empty,
                else => @field(dispatch.Action, @tagName(route)),
            };

            const row = @backingInt(id);
            const type_id: ir.TypeId = @fromBackingInt(lowering.program.expressions.types[row]);

            return read.lower(lowering, row, type_id, action, true, self);
        },
        .Update => return @import("mutation.zig").update(self, id),
        .Mutation => return @import("mutation.zig").operation(self, id),
        .Aggregate => return @import("aggregate.zig").lower(self, id),
        .Collection => {
            const type_id: ir.TypeId = @fromBackingInt(lowering.program.expressions.types[@backingInt(id)]);

            return collections.lowerValue(lowering, id, try @import("types.zig").get(self, type_id));
        },
        else => {},
    }

    const value = lowering.program.expression(id);

    return try switch (plan.route) {
        .Scope => @import("scope.zig").lower(self, value.value.scope),
        .List => @import("list.zig").lower(self, value.type_id, value.value.list),
        .Call => @import("invocation.zig").lower(self, id, value, plan.value_call),
        .Conditional => @import("../selection/conditional.zig").lower(lowering, value.value.conditional),
        .Match => @import("../match.zig").lower(lowering, value.value.match_expr),
        else => unreachable,
    };
}

const entry = @import("generated_iteration_evaluation");
const Plan = @typeInfo(@typeInfo(@TypeOf(entry.executeValue)).@"fn".return_type.?).error_union.payload;

fn select(self: *const Context, id: ir.ExprId, probe: Probe) Plan {
    const Input = std.meta.Child(entry.Input);
    const lowering = self.lowering;
    const program: *const ir.Program = &lowering.program;
    const expressions = zx.columns.borrow(std.meta.Child(@FieldType(Input, "expressions")), &program.expressions);
    const Cache = std.meta.Child(@FieldType(Input, "cache"));
    const cache = self.cache.view(Cache);
    const regular = lowering.cache.view(std.meta.Child(@FieldType(Input, "regular")));
    const symbols = self.symbols.view(std.meta.Child(@FieldType(Input, "symbols")));
    const checked = probe.view(std.meta.Child(@FieldType(Input, "probe")));

    const input: Input = .{
        .expressions = &expressions,
        .type_kinds = program.types.kinds,
        .layouts = zx.columns.slice(@FieldType(Input, "layouts"), lowering.layout_types),
        .inline_lists = self.inline_lists,
        .cache = &cache,
        .regular = &regular,
        .probe = &checked,
        .symbols = &symbols,
        .value_functions = lowering.value_functions,
        .argument = if (self.argument) |argument| @backingInt(argument.id) else null,
        .id = @backingInt(id),
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(entry.executeValue, empty.allocator(), &input) catch unreachable;
}

pub fn unpack(self: *Context, id: ir.ExprId, input: node.ExpressionId) Lower.Error!node.ExpressionId {
    const lowering = self.lowering;
    const generated = @import("genz_options").generated_analysis;
    var body: Context.Statements = if (generated) lowering.builder.statementSequence(lowering.workspace) else .empty;

    defer if (generated) body.deinit();

    const value = try aggregate.bind(lowering, &body, input);
    const type_id: ir.TypeId = @fromBackingInt(lowering.program.expressions.types[@backingInt(id)]);

    return aggregate.finish(lowering, &body, try @import("conversion.zig").convert(self, type_id, value, false));
}
