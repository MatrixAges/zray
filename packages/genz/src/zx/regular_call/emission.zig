const std = @import("std");
const zx = @import("zx");
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const reference = @import("../functions/reference.zig");
const OriginBuffer = @import("../construction/publication.zig").OriginBuffer;
const entry = @import("generated_regular_call_emit");
const Input = std.meta.Child(entry.Input);

pub const Request = struct {
    function: zx.ir.FunctionId,
    value: node.ExpressionId,
    store: ?node.ExpressionId,
    io: bool,
    process: bool,
};

pub fn lower(self: *Lower, request: Request) Lower.Error!node.ExpressionId {
    const target = reference.prepare(self, request.function, .regular);
    var origin: OriginBuffer = undefined;

    const input: Input = .{
        .frame = @ptrCast(self),
        .writer = @ptrCast(self),
        .origin = @ptrCast(&origin),
        .target = zx.columns.pointer(@FieldType(Input, "target"), &target),
        .value = @backingInt(request.value),
        .store = if (request.store) |store| @backingInt(store) else null,
        .io = request.io,
        .process = request.process,
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const temporary = memory.allocator();
    const root = entry.executeIn(temporary, &input) catch |err| return reference.failure(err);

    return @fromBackingInt(root);
}
