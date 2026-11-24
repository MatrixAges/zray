const std = @import("std");
const Lower = @import("../lower.zig");
const Stored = @import("../../node/stored.zig").Declarations;
const count = 6;

/// List growth emitted into generated code: an append allocates a buffer with a header recording its capacity and the
/// length of the furthest value built on it. Appending to a value at that frontier writes in place and moves the
/// frontier; any other value copies, so older values never see the write. Only the values the uniqueness plan proves
/// headered are checked, and a pop of a unique headered value hands the frontier back. A loop whose state must own a
/// list renews it once on entry, copying the records on the way so the loop never writes into its initial value.
pub fn publish(self: *Lower, exported: bool) Lower.Error!Stored {
    const entry = @import("generated_growth_declarations");
    const Parameter = @typeInfo(@TypeOf(entry.executeValue)).@"fn".param_types[1].?;
    const indirect = @typeInfo(Parameter) == .pointer;
    const Input = if (indirect) std.meta.Child(Parameter) else Parameter;
    const Bases = std.meta.Child(@FieldType(Input, "bases"));
    const bases = @import("../construction/context.zig").snapshot(Bases, self);
    const input: Input = .{ .bases = &bases, .exported = exported, .shared_types = self.shared_types };
    const output = entry.executeValue(self.allocator, if (indirect) &input else input) catch |err| return failure(err);

    if (!output.valid) return error.OutOfMemory;

    const first = self.builder.nodes.declaration_rows.tags.items.len;
    const Output = std.meta.Child(entry.Output);

    @import("../../node/import_module.zig").appendBorrowed(self.allocator, self.builder.nodes, Output, output) catch |err| return failure(err);

    std.debug.assert(output.declarations.tags.len == count);

    self.uses_allocator = self.uses_allocator or output.uses_allocator;

    return .{ .start = @intCast(first), .len = count };
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => @panic("invalid growth declarations AST"),
    };
}
