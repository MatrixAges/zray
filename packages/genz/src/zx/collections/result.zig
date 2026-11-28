const std = @import("std");
const zx = @import("zx");
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const publication = @import("../construction/publication.zig");
const Sequence = @import("../../node/blocks.zig").Sequence;
const entry = @import("generated_collection_result");
const Input = std.meta.Child(entry.Input);
const Source = std.meta.Child(@FieldType(Input, "source"));
const Bases = std.meta.Child(@FieldType(Source, "bases"));
const Preparation = std.meta.Child(@FieldType(Input, "preparation"));
const Conversion = std.meta.Child(@FieldType(Preparation, "source"));

pub fn lower(self: *Lower, body: *Sequence, result_type: zx.ir.TypeId, value: node.ExpressionId) Lower.Error!node.ExpressionId {
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const types = self.program.typeOf(result_type).tuple;
    const type_table = zx.ir.TypeTable.borrow(std.meta.Child(@FieldType(Conversion, "types")), self.program.types);
    const bases = @import("../construction/context.zig").snapshot(Bases, self);

    const input: Input = .{
        .frame = @ptrCast(self),
        .writer = @ptrCast(self),
        .body = @ptrCast(body),
        .source = &.{ .value = @backingInt(value), .bases = &bases },
        .preparation = &.{
            .types = types.values[0..types.len],
            .source = &.{
                .types = &type_table,
                .queries = zx.columns.slice(@FieldType(Conversion, "queries"), self.state_plan.queries),
                .selected = self.state_plan.selected,
                .element_storage = self.state_plan.element_storage,
            },
            .resources = &.{
                .frame = @ptrCast(self),
                .types = &.{
                    .abi_types = @ptrCast(self.abi_types),
                    .abi_layouts = @ptrCast(self.abi_layouts),
                    .state_types = @ptrCast(self.state_types),
                    .state_layouts = @ptrCast(self.state_layouts),
                    .views = @ptrCast(self.view_types),
                },
                .children = self.program.types.first,
                .referenced = self.state_plan.borrowed,
            },
            .shared = self.shared_types,
        },
    };

    const root = entry.executeIn(memory.allocator(), &input) catch |err| return publication.failure(err);

    return @fromBackingInt(root);
}
