const std = @import("std");
const zx = @import("zx");
const Lower = @import("../lower.zig");
const payloads = @import("../../node/import_payloads.zig");

pub fn append(self: *Lower, source: anytype) Lower.Error!void {
    if (source.tags.len == 0) return;
    try self.reference_storage.ensureUnusedCapacity(self.allocator, 1);

    const entry = @import("generated_append_references");
    const Input = std.meta.Child(entry.Input);
    const Payload = std.meta.Child(@FieldType(Input, "payload"));
    const target = &self.builder.nodes.statements;
    var binding: payloads.Binding(@TypeOf(target), std.meta.Child(@TypeOf(source)), .selected) = .{};
    const payload = binding.bind(Payload, &self.allocator, target, source, true, false);
    const input: Input = .{ .payload = &payload };
    var scratch_buf: [2048]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(self.allocator);

    defer arena.deinit();

    var fallback = std.heap.BufferFirstAllocator.init(&scratch_buf, arena.allocator());

    const result = zx.columns.invoke(entry.executeValue, fallback.allocator(), &input) catch |err| return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };

    switch (result.check) {
        .Valid => self.reference_storage.appendAssumeCapacity(result.span),
        .Invalid => unreachable,
        .Exhausted => return error.OutOfMemory,
    }
}
