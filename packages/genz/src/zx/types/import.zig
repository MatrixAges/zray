const std = @import("std");
const zx = @import("zx");
const view = @import("../../node/view.zig");
const module = @import("../../node/import_module.zig");
const Lower = @import("../lower.zig");
pub const Pending = @import("../../node/declarations.zig").Output;

/// Field names must outlive the AST; retained payloads already belong to its allocator.
pub fn append(self: *Lower, declarations: ?*Pending, comptime Output: type, output: anytype, fields: anytype, mode: module.Mode) Lower.Error!void {
    const Expressions = std.meta.Child(@FieldType(Output, "expressions"));
    const Definitions = std.meta.Child(@FieldType(Output, "definitions"));
    var expressions: Expressions = undefined;
    var definitions: Definitions = undefined;

    inline for (@typeInfo(Expressions).@"struct".field_names) |name| @field(expressions, name) = @field(output.expressions, name);
    inline for (@typeInfo(Definitions).@"struct".field_names) |name| @field(definitions, name) = @field(output.definitions, name);

    const combined = view.join(expressions, definitions);
    const Constants = std.meta.Child(@FieldType(Output, "declarations"));
    const constants = zx.columns.view(Constants, output.declarations);
    const nodes = self.builder.nodes;
    const start = nodes.declaration_rows.tags.items.len;

    switch (mode) {
        inline else => |selected| module.appendColumns(self.allocator, nodes, .{
            .expressions = combined,
            .statements = {},
            .fields = fields,
            .declarations = constants,
        }, .{
            .expressions = selected,
            .declarations = if (selected == .owned) .owned else .borrowed,
            .borrow_field_text = true,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidAst => unreachable,
        },
    }

    if (declarations) |roots| try roots.spans.append(.{ .start = @intCast(start), .len = @intCast(constants.tags.len) });
}
