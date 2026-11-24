const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../node.zig");
const Lower = @import("lower.zig");
const OriginBuffer = @import("construction/publication.zig").OriginBuffer;
pub const declaration = @import("store/transaction.zig").declaration;

pub fn adapter(self: *Lower, invocation: @FieldType(@FieldType(ir.ExpressionRow, "value"), "call")) Lower.Error!node.ExpressionId {
    if (!@import("genz_options").generated_analysis) return @import("store/adapter_seed.zig").lower(self, invocation);

    const entry = @import("generated_store_adapter");
    const Input = std.meta.Child(entry.Input);
    const slots = self.program.functions.stores[@backingInt(invocation.function)];
    var origin: OriginBuffer = .{};

    const input: Input = .{
        .writer = @ptrCast(self),
        .origin = @ptrCast(&origin),
        .frame = @ptrCast(self),
        .mapping = invocation.stores,
        .readable = slots.readable,
        .store_count = self.program.stores.count(),
        .pending_name = self.pending_name,
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);

    defer scratch.deinit();

    const root = entry.executeIn(scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    return @fromBackingInt(root);
}
