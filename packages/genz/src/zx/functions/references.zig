const std = @import("std");
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
    const input: Input = .{ .payload = &payload, .spans = @ptrCast(&self.reference_storage) };

    payloads.invoke(entry.executeValue, &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidAst => unreachable,
    };
}
