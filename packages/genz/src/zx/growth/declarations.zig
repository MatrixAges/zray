const std = @import("std");
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const Stored = @import("../../node/stored.zig").Declarations;
const count = 6;

pub fn lower(self: *Lower, exported: bool) Lower.Error![count]node.Declaration {
    const stored = try publish(self, exported);
    var result: [count]node.Declaration = undefined;

    for (&result, 0..) |*declaration, index| {
        declaration.* = try self.builder.nodes.materializeDeclaration(self.allocator, stored.start + @as(u32, @intCast(index)));
    }

    return result;
}

pub fn publish(self: *Lower, exported: bool) Lower.Error!Stored {
    const entry = @import("generated_growth_declarations");
    const Parameter = @typeInfo(@TypeOf(entry.executeValue)).@"fn".param_types[1].?;
    const indirect = @typeInfo(Parameter) == .pointer;
    const Input = if (indirect) std.meta.Child(Parameter) else Parameter;
    const Bases = std.meta.Child(@FieldType(Input, "bases"));
    const Capture = std.meta.Child(@typeInfo(@FieldType(Bases, "capture")).optional.child);
    var capture: Capture = undefined;

    const bases: Bases = .{
        .capture = if (self.capture) |boundary| captured: {
            capture = .{ .name = boundary.name, .label = boundary.label, .failure = @backingInt(boundary.failure) };

            break :captured &capture;
        } else null,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(self.builder.nodes.statements.tags.items.len),
        .field_base = @intCast(self.builder.nodes.field_columns.count()),
        .serial = self.serial,
    };

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
