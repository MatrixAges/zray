const std = @import("std");
const zx = @import("zx");
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const policy = @import("policy.zig");
const reference = @import("../functions/reference.zig");
const Variant = @import("../functions/requests.zig").Variant;
const Sequence = @import("../../node/blocks.zig").Sequence;
const entry = @import("generated_value_call_emit");
const Input = std.meta.Child(entry.Input);
const Context = std.meta.Child(@FieldType(Input, "context"));
const Capture = std.meta.Child(@typeInfo(@FieldType(Context, "capture")).optional.child);
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
    const statement_base: u32 = @intCast(self.builder.nodes.statements.tags.items.len);
    var boundary: Capture = undefined;

    const capture = if (self.capture) |captured| capture: {
        boundary = .{ .name = captured.name, .label = captured.label, .failure = @backingInt(captured.failure) };

        break :capture &boundary;
    } else null;

    const context: Context = .{
        .capture = capture,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = statement_base,
        .field_base = @intCast(self.builder.nodes.field_columns.count()),
        .serial = self.serial,
    };

    const plan: Plan = if (arguments.plan) |selected| zx.columns.view(Plan, selected) else undefined;

    const variant: Variant = if (arguments.plan) |selected| switch (selected.variant) {
        .Regular => .regular,
        .Value => .value,
    } else undefined;

    const target: Target = if (arguments.function) |id| zx.columns.view(Target, reference.prepare(self, id, variant)) else undefined;

    const input: Input = .{
        .context = &context,
        .value = @backingInt(arguments.value),
        .target = if (arguments.function != null) &target else null,
        .plan = if (arguments.plan != null) &plan else null,
    };

    const output = entry.executeIn(allocator, &input) catch |err| return failure(err);

    if (!output.context.valid) return error.OutOfMemory;

    return @import("../invocation/publication.zig").write(self, if (arguments.function) |id| .{ .id = id, .variant = variant } else null, .{ .value = .{
        .output = output,
        .body = body,
    } });
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => @panic("invalid value call emission"),
    };
}
