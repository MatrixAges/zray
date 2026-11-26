const std = @import("std");
const zx = @import("zx");
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const policy = @import("policy.zig");
const reference = @import("../functions/reference.zig");
const Variant = @import("../functions/requests.zig").Variant;
const Sequence = @import("../../node/blocks.zig").Sequence;
const OriginBuffer = @import("../construction/publication.zig").OriginBuffer;
const entry = @import("generated_value_call_emit");
const Input = std.meta.Child(entry.Input);
const Plan = std.meta.Child(@typeInfo(@FieldType(Input, "plan")).optional.child);
const Target = std.meta.Child(@typeInfo(@FieldType(Input, "target")).optional.child);

pub const Arguments = struct {
    value: node.ExpressionId,
    function: ?zx.ir.FunctionId = null,
    plan: ?policy.Plan = null,
};

pub fn emit(self: *Lower, body: ?*Sequence, arguments: Arguments) Lower.Error!node.ExpressionId {
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const allocator = buffered.allocator();
    var origin: OriginBuffer = undefined;
    const plan: Plan = if (arguments.plan) |selected| zx.columns.view(Plan, selected) else undefined;

    const variant: Variant = if (arguments.plan) |selected| switch (selected.variant) {
        .Regular => .regular,
        .Value => .value,
    } else undefined;

    const target: Target = if (arguments.function) |id| zx.columns.view(Target, reference.prepare(self, id, variant)) else undefined;

    const input: Input = .{
        .frame = @ptrCast(self),
        .writer = @ptrCast(self),
        .origin = @ptrCast(&origin),
        .body = if (body) |sequence| @ptrCast(sequence) else null,
        .value = @backingInt(arguments.value),
        .target = if (arguments.function != null) &target else null,
        .plan = if (arguments.plan != null) &plan else null,
    };

    const root = entry.executeIn(allocator, &input) catch |err| return failure(err);

    return @fromBackingInt(root);
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => @panic("invalid value call emission"),
    };
}
