const std = @import("std");
const zx = @import("zx");
const Statements = @import("../statements.zig");
const Flow = @import("../flow.zig");
const Writer = @import("../control/writer.zig");
const generated = @import("rx_options").generated_graph;

pub fn lower(self: *const Statements, allocator: std.mem.Allocator, root_writer: *Writer.Cursor) Statements.Error!void {
    if (comptime !generated) return @import("traversal/seed.zig").lower(self, allocator, root_writer);

    const rule = @import("generated_rx_execute_statements");
    const Input = std.meta.Child(rule.Input);
    const Shape = std.meta.Child(@FieldType(Input, "shape"));
    const Steps = std.meta.Child(@FieldType(Shape, "steps"));
    const flow = self.flow;
    const steps = flow.steps.slice();
    const cases = flow.cases.slice();
    const units = flow.units.slice();
    const layout = std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(self.plan.rows));
    const root = self.plan.root();

    var state: @import("traversal/host.zig").State = .{
        .statements = self,
        .allocator = allocator,
        .root = root,
        .root_writer = root_writer,
    };

    const input: Input = .{
        .frame = @ptrCast(&state),
        .shape = &.{
            .steps = &.{
                .kinds = zx.columns.slice(@FieldType(Steps, "kinds"), @as([]const Flow.Kind, steps.items(.kind))),
                .outputs = zx.columns.slice(@FieldType(Steps, "outputs"), @as([]const Flow.Publish, steps.items(.output))),
                .firsts = steps.items(.first),
                .counts = steps.items(.count),
                .exhaustive = steps.items(.exhaustive),
            },
            .units = &.{
                .firsts = units.items(.first),
                .counts = units.items(.count),
                .blocks = units.items(.block),
            },
            .cases = cases.items(.body),
        },
        .layout = layout,
        .borrow_root = self.retain_metadata,
    };

    const bindings = self.builder.bindings.items.len;

    errdefer self.restoreBindings(bindings);

    return rule.executeValue(allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        error.UnreachableFlow => error.UnreachableFlow,
        error.IncompleteFlow => error.IncompleteFlow,
        else => error.InvalidModule,
    };
}
