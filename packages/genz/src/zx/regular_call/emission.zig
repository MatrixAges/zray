const std = @import("std");
const zx = @import("zx");
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const reference = @import("../functions/reference.zig");
const entry = @import("generated_regular_call_emit");
const Input = std.meta.Child(entry.Input);
const Capture = std.meta.Child(@typeInfo(@FieldType(Input, "capture")).optional.child);

pub const Request = struct {
    function: zx.ir.FunctionId,
    allocator: node.ExpressionId,
    value: node.ExpressionId,
    store: ?node.ExpressionId,
    io: bool,
    process: bool,
};

pub fn lower(self: *Lower, request: Request) Lower.Error!node.ExpressionId {
    const target = try reference.prepare(self, request.function, .regular);
    var capture: Capture = undefined;

    const input: Input = .{
        .base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .target = zx.columns.pointer(@FieldType(Input, "target"), &target),
        .allocator = @backingInt(request.allocator),
        .value = @backingInt(request.value),
        .store = if (request.store) |store| @backingInt(store) else null,
        .io = request.io,
        .process = request.process,
        .capture = if (self.capture) |boundary| captured: {
            capture = .{ .name = boundary.name, .label = boundary.label, .failure = @backingInt(boundary.failure) };

            break :captured &capture;
        } else null,
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const temporary = memory.allocator();
    const output = entry.executeIn(temporary, &input) catch |err| return reference.failure(err);

    if (!output.valid) return error.OutOfMemory;

    try reference.publish(self, temporary, output.nodes, target.module == null);

    self.uses_allocator = true;
    self.uses_io = self.uses_io or request.io;
    self.uses_process = self.uses_process or request.process;

    return @fromBackingInt(output.root);
}
