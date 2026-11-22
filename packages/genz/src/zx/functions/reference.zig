const std = @import("std");
const zx = @import("zx");
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const Variant = @import("requests.zig").Variant;
const entry = @import("generated_function_reference");
const Input = std.meta.Child(entry.Input);
const Target = std.meta.Child(@FieldType(Input, "target"));

pub fn prepare(self: *const Lower, id: zx.ir.FunctionId, variant: Variant) Target {
    const module = if (self.function_modules) |modules| modules[@backingInt(id)] else null;

    return .{
        .id = @backingInt(id),
        .variant = switch (variant) {
            .regular => .Regular,
            .value => .Value,
        },
        .module = module,
        .recursive = id == self.self_function,
        .local_regular = self.local_regular_function,
    };
}

pub fn lower(self: *Lower, id: zx.ir.FunctionId, variant: Variant) Lower.Error!node.ExpressionId {
    const target = prepare(self, id, variant);

    const input: Input = .{
        .target = &target,
        .base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .identifiers = 0,
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const temporary = memory.allocator();
    const output = entry.executeIn(temporary, &input) catch |err| return failure(err);

    return @import("../invocation/publication.zig").write(self, .{ .id = id, .variant = variant }, .{ .reference = output });
}

pub fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => @panic("invalid function reference emission"),
    };
}
