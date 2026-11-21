const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Context = @import("root.zig");
const Lower = @import("../lower.zig");
const aggregate = @import("../aggregate.zig");
const Probe = @import("../expression_map.zig").Probe;

pub fn lower(self: *Context, id: ir.ExprId, probe: Probe) Lower.Error!node.ExpressionId {
    return @import("../expressions/evaluate.zig").iteration(self, id, select(self, id, probe));
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
