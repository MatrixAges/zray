const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const Sequence = @import("../../node/blocks.zig").Sequence;

pub fn bind(self: *Lower, body: anytype, transform: ir.Transform) Lower.Error!void {
    if (transform.kind == .reduce) return;

    const initial = transform.initial orelse return;
    const value = try self.expr(initial);
    const symbol = @backingInt(transform.parameters[1]);

    const statement: node.Statement = if (self.used[symbol])
        .{ .constant = .{
            .name = self.names[symbol],
            .type_expr = try self.typeExpr(self.program.symbols.at(symbol).type_id),
            .value = value,
        } }

    else
        .{ .discard = value };

    if (@TypeOf(body) == *Sequence) {
        return body.append(try self.builder.statements(&.{statement}));
    }

    return body.append(self.allocator, statement);
}
