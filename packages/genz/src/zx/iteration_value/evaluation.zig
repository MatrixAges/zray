const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Context = @import("root.zig");
const Lower = @import("../lower.zig");
const aggregate = @import("../aggregate.zig");
const collections = @import("../collections.zig");
const read = @import("../access/projection/read.zig");
const access = @import("../access/emit.zig");

pub fn lower(self: *Context, id: ir.ExprId) Lower.Error!?node.ExpressionId {
    const lowering = self.lowering;
    const plan = select(self, id);

    switch (plan.route) {
        .Argument => return self.argument.?.value,
        .Cached => {
            try self.reads.increment(lowering.allocator, id);

            return @fromBackingInt(plan.value.?);
        },
        .Fallback => return null,
        .Unpack => return try unpack(self, id),
        else => {},
    }

    const value = lowering.program.expression(id);

    return try switch (plan.route) {
        .Reference => reference(lowering, value.value.reference),
        .Field => read.field(lowering, value.type_id, value.value.field, true),
        .Unwrap => access.optional(lowering, null, try lowering.expr(value.value.optional_value)),
        .TupleField => read.tuple(lowering, value.type_id, value.value.tuple_field, true),
        .Scope => @import("scope.zig").lower(self, value.value.scope),
        .Index => read.index(lowering, value.type_id, value.value.index.target, value.value.index.index, true),
        .Length => read.length(lowering, value.value.length, try lowering.typeExpr(value.type_id), true),
        .Update => @import("mutation.zig").update(self, id),
        .Mutation => @import("mutation.zig").operation(self, id),
        .List => @import("list.zig").lower(self, value.type_id, value.value.list),
        .Call => @import("invocation.zig").lower(self, id, value.value.call.argument),
        .None => access.optional(lowering, try @import("types.zig").get(self, value.type_id), null),
        .Some => access.optional(lowering, try @import("types.zig").get(self, value.type_id), try lowering.expr(value.value.some)),
        .Binary => lowering.regular(id),
        .Aggregate => @import("aggregate.zig").lower(self, id),
        .Collection => collections.lowerValue(lowering, id, try @import("types.zig").get(self, value.type_id)),
        .Conditional => @import("../selection/conditional.zig").lower(lowering, value.value.conditional),
        .Match => @import("../match.zig").lower(lowering, value.value.match_expr),
        else => unreachable,
    };
}

const entry = @import("generated_iteration_evaluation");
const Plan = @typeInfo(@typeInfo(@TypeOf(entry.executeValue)).@"fn".return_type.?).error_union.payload;

fn select(self: *const Context, id: ir.ExprId) Plan {
    const Input = std.meta.Child(entry.Input);
    const lowering = self.lowering;
    const program: *const ir.Program = &lowering.program;
    const expressions = zx.columns.borrow(std.meta.Child(@FieldType(Input, "expressions")), &program.expressions);
    const Cache = std.meta.Child(@FieldType(Input, "cache"));
    const cache = self.cache.view(Cache);
    const regular = lowering.cache.view(std.meta.Child(@FieldType(Input, "regular")));
    const symbols = self.symbols.view(std.meta.Child(@FieldType(Input, "symbols")));

    const input: Input = .{
        .expressions = &expressions,
        .type_kinds = program.types.kinds,
        .layouts = zx.columns.slice(@FieldType(Input, "layouts"), lowering.layout_types),
        .inline_lists = self.inline_lists,
        .cache = &cache,
        .regular = &regular,
        .symbols = &symbols,
        .argument = if (self.argument) |argument| @backingInt(argument.id) else null,
        .id = @backingInt(id),
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(entry.executeValue, empty.allocator(), &input) catch unreachable;
}

fn reference(lowering: *Lower, symbol: ir.SymbolId) Lower.Error!node.ExpressionId {
    const row = @backingInt(symbol);

    lowering.used[row] = true;

    return lowering.builder.identifier(lowering.names[row]);
}

pub fn unpack(self: *Context, id: ir.ExprId) Lower.Error!node.ExpressionId {
    const lowering = self.lowering;
    const generated = @import("genz_options").generated_analysis;
    var body: Context.Statements = if (generated) lowering.builder.statementSequence(lowering.workspace) else .empty;

    defer if (generated) body.deinit();

    const value = try aggregate.bind(lowering, &body, try lowering.regular(id));

    return aggregate.finish(lowering, &body, try @import("conversion.zig").convert(self, lowering.program.expression(id).type_id, value, false));
}
