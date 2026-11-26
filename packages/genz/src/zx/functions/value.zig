const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const policy = @import("policy.zig");
const state = @import("../state_value/root.zig");
const scope = @import("../state_value/scope.zig");
const argument: ir.SymbolId = @fromBackingInt(0);
const Error = Lower.Error;

pub fn lower(self: *Lower, name: []const u8, comptime signature: bool) Error!node.Declaration {
    const mode = policy.value(self);
    const representation = if (mode.enter) try state.enter(self) else null;

    defer if (representation) |saved| saved.restore();

    if (mode.bind_input) try self.state_symbols.put(self.allocator, argument, {});

    defer _ = self.state_symbols.remove(argument);
    const output = scope.enter(self, .Value, .{ .value_output = mode.value_output });

    defer output.restore();

    return if (signature) .{ .function = try self.prototype(name, false) } else try self.function(name, false);
}
