const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");

pub fn lower(self: *Lower, slot: u32, type_id: ir.TypeId) Lower.Error!node.ExpressionId {
    if (!@import("genz_options").generated_analysis) return @import("store_seed.zig").lower(self, slot, type_id);

    const entry = @import("generated_store_access");
    const Input = std.meta.Child(entry.Input);
    const row = @backingInt(type_id);

    const input: Input = .{
        .writer = @ptrCast(self),
        .frame = @ptrCast(self),
        .type_id = row,
        .slot = slot,
        .type_kind = self.program.types.kinds[row],
        .query = zx.columns.view(@FieldType(Input, "query"), self.state_plan.queries[row]),
        .active = self.state_active,
        .store_count = self.program.stores.count(),
        .store_mode = switch (self.program.store_mode) {
            .transaction => .transaction,
            .orchestration => .orchestration,
        },
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const root = entry.executeIn(buffered.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    return @fromBackingInt(root);
}
