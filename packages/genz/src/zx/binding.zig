const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../node.zig");
const Lower = @import("lower.zig");
const generated = @import("genz_options").generated_analysis;
const seed = @import("binding/seed.zig");
pub const Route = seed.Route;
pub const before = seed.before;

pub const Declaration = struct {
    symbol: ?ir.SymbolId,
    value: node.ExpressionId,
    by_value: bool,
    scope: bool = false,
    mutable: bool = false,
};

pub fn publish(self: *Lower, output: anytype, declaration: Declaration) Lower.Error!node.Block {
    if (!generated) return seed.publish(self, output, declaration);

    const entry = @import("generated_publish_binding");
    const Input = std.meta.Child(entry.Input);
    const symbol = if (declaration.symbol) |id| @backingInt(id) else null;
    const used = if (symbol) |id| self.used[id] else false;
    const layout = if (declaration.scope) self.loop_fields else null;
    const loop_field = if (layout) |fields| if (declaration.symbol) |id| fields.symbol(id) else false else false;

    const input: Input = .{
        .writer = @ptrCast(self),
        .sequence = @ptrCast(output),
        .frame = @ptrCast(self),
        .policy = &.{
            .has_symbol = symbol != null,
            .used = used,
            .by_value = declaration.by_value,
            .loop_field = loop_field,
            .mutable = declaration.mutable,
        },
        .type_id = if (used) self.program.symbols.types[symbol.?] else 0,
        .loop_layout = if (loop_field) @backingInt(layout.?.layout) else null,
        .name = if (used) self.names[symbol.?] else &.{},
        .value = @backingInt(declaration.value),
    };

    return @import("construction/publication.zig").executeSpan(self, entry, &input);
}
