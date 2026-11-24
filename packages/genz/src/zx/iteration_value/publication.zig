const std = @import("std");
const zx = @import("zx");
const Lower = @import("../lower.zig");
const Context = @import("root.zig");
const Sequence = @import("../../node/blocks.zig").Sequence;
const Fragment = @import("../construction/publication.zig").Frame;
const evaluation = @import("../expressions/evaluate.zig");
const entry = @import("generated_publish_iteration_ast");
const Input = std.meta.Child(entry.Input);
const Mode = @FieldType(std.meta.Child(@FieldType(Input, "rows")), "mode");
const Error = Lower.Error;
const Transfer = std.meta.Child(@import("generated_iteration_transfer").Output);
const TypeCache = struct { ids: []const u32, values: []const u32 };
const Rows = std.meta.Child(@FieldType(Fragment, "statements"));

const Frame = struct {
    lowering: *Lower,
    context: ?*Context,
    labels: []const []const u8,
    record: ?@FieldType(Transfer, "record"),
    cache: ?TypeCache,
    label: ?[]const u8 = null,
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub const Scope = struct {
    context: ?*Context = null,
    body: ?*Sequence = null,
};

pub fn write(self: *Lower, comptime mode: Mode, scope: Scope, output: anytype) Error!void {
    const result = if (mode == .Returned) output.result else output;
    const statements: ?Rows = if (mode != .Buffer) zx.columns.pointer(Rows, result.statements) else null;

    const fragment: Fragment = .{
        .lower = self,
        .targets = .{ .body = scope.body },
        .expressions = zx.columns.pointer(@FieldType(Fragment, "expressions"), result.expressions),
        .forms = if (mode != .Types) zx.columns.pointer(std.meta.Child(@FieldType(Fragment, "forms")), result.forms) else null,
        .layouts = if (mode == .Types) result.layouts else null,
        .statements = statements,
        .fields = if (mode != .Transfer and mode != .PrepareBuffer)
            zx.columns.pointer(std.meta.Child(@FieldType(Fragment, "fields")), result.fields)
        else
            null,
        .roots = switch (mode) {
            .Input => zx.columns.pointer(Rows, result.declarations),
            .Returned => zx.columns.pointer(Rows, output.storage),
            .Transfer => zx.columns.pointer(Rows, result.prefix),
            .PrepareBuffer => zx.columns.pointer(Rows, result.roots),
            else => statements,
        },
        .vars = if (mode == .Input or mode == .Returned or mode == .Transfer)
            zx.columns.pointer(std.meta.Child(@FieldType(Fragment, "vars")), result.variables)
        else
            null,
    };

    var frame: Frame = .{
        .lowering = self,
        .context = scope.context,
        .labels = if (mode == .Mutation) fragment.expressions.block_label else &.{},
        .record = if (mode == .Transfer) result.record else null,
        .cache = if (mode == .Types) .{ .ids = result.cache_types, .values = result.cache_values } else null,
    };

    const input: Input = .{
        .target = @ptrCast(&frame),
        .lower = @ptrCast(self),
        .rows = &.{ .fragment = @ptrCast(&fragment), .mode = mode },
        .valid = result.valid,
        .serial = switch (mode) {
            .Projection, .Buffer, .PrepareBuffer => null,
            else => @intCast(result.serial),
        },
        .uses_allocator = switch (mode) {
            .Input, .Returned, .Mutation => result.uses_allocator,
            else => false,
        },
    };

    return evaluation.execute(entry, &input);
}

pub fn ownIterationLabel(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    frame.label = try frame.lowering.allocator.dupe(u8, frame.labels[frame.labels.len - 1]);
}

pub fn repairIterationBlockLabel(handle: *const anyopaque) void {
    const frame = Frame.borrow(handle);
    const expressions = &frame.lowering.builder.nodes.expressions;
    const labels = expressions.payloads.block.fields.label.values.items;

    labels[labels.len - 1] = frame.label.?;
}

pub fn repairIterationBreakLabel(handle: *const anyopaque) void {
    const frame = Frame.borrow(handle);
    const statements = &frame.lowering.builder.nodes.statements;
    const labels = statements.payloads.break_value.fields.label.values.items;

    labels[labels.len - 1] = frame.label.?;
}

pub fn cachePublishedIterationTypes(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const cache = frame.cache.?;

    return @import("resources.zig").publish(frame.context.?, cache.ids, cache.values);
}

pub fn recordIterationTransfer(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    return frame.context.?.transfers.retain(frame.lowering.allocator, frame.record.?);
}
