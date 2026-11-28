const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../node.zig");
const Lower = @import("lower.zig");
const publication = @import("construction/publication.zig");
const Error = Lower.Error;
const Work = @import("collections/branch.zig");

pub fn lower(self: *Lower, id: ir.ExprId) Error!node.ExpressionId {
    if (comptime !@import("genz_options").generated_analysis) return @import("list_update_seed.zig").lower(self, id);

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
    const flags = self.plan.get(id);
    const represented = @import("state_value/list.zig").selected(self, source_type);

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
        .deferred = represented and self.deferred_lists,
        .in_place = flags.in_place,
        .grow = flags.grow,
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
