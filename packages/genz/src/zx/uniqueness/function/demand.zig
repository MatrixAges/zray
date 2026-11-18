const std = @import("std");
const zx = @import("zx");
const Function = @import("../function.zig");
const levels = @import("levels.zig");
const rows = @import("../row_output.zig");
const publishing = @import("generated_uniqueness_result_demand");
const Publication = std.meta.Child(publishing.Input);
const Targets = rows.Target(Publication, "growth");
const generated = @import("generated_uniqueness_function_demand");
const AbiInput = std.meta.Child(generated.Input);
const Source = std.meta.Child(@FieldType(AbiInput, "source"));

pub fn analyze(function: *Function, owner: std.mem.Allocator) std.mem.Allocator.Error!Function.Demand {
    const Parameter = @typeInfo(@TypeOf(generated.executeValue)).@"fn".param_types[1].?;
    const indirect = @typeInfo(Parameter) == .pointer;
    const Input = if (indirect) std.meta.Child(Parameter) else Parameter;
    var borrowed: levels.Borrowed = undefined;

    try borrowed.init(function);

    const source: Source = .{
        .kinds = function.slots.types.kinds,
        .native_modules = function.functions.native_modules,
        .carried = function.evaluation.?.carried,
        .inputs = @ptrCast(&function.summaries.inputs),
        .outputs = @ptrCast(&function.summaries.outputs),
        .function_index = if (function.function) |index| @intCast(index) else null,
        .deferred = function.deferred,
        .record_marks = true,
        .entry_dirty = null,
        .operations = @ptrCast(function.operations),
        .results = @ptrCast(function.order.results),
    };

    const input: Input = .{
        .context = if (@typeInfo(@FieldType(Input, "context")) == .pointer) &borrowed.descriptor else borrowed.context,
        .known = function.evaluation.?.known,
        .source = if (@typeInfo(@FieldType(Input, "source")) == .pointer) &source else zx.columns.borrow(@FieldType(Input, "source"), &source),
    };

    const result = generated.executeValue(function.allocator, if (indirect) &input else input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.debug.panic("function demand failed: {s}", .{@errorName(err)}),
    };

    const before = function.evaluation.?.reads;
    function.evaluation.?.known = result.known;
    function.evaluation.?.reads = result.reads;
    function.grew = function.grew or result.grew;
    var normalized: rows.Normalized(Targets) = undefined;
    var renewed: rows.Renewed(Targets) = undefined;
    var reads: rows.Reads(Publication) = undefined;
    var marks: rows.Marks(Publication, "mark_target") = undefined;

    normalized.init();
    renewed.init();
    reads.init();
    marks.init();
    errdefer owner.free(normalized.rows());
    errdefer owner.free(renewed.rows());
    errdefer owner.free(reads.rows());
    errdefer owner.free(marks.rows());

    const input_rows: Publication = .{
        .marks = zx.columns.slice(@FieldType(Publication, "marks"), result.marks),
        .before = zx.columns.slice(@FieldType(Publication, "before"), before),
        .after = zx.columns.slice(@FieldType(Publication, "after"), result.reads),
        .normalized = zx.columns.slice(@FieldType(Publication, "normalized"), result.context.normalized),
        .renewed = zx.columns.slice(@FieldType(Publication, "renewed"), result.context.renewed),
        .growth = if (result.grew) &.{
            .normalized = &.{ .storage = @ptrCast(&normalized.buffer), .columns = &normalized.view },
            .renewed = &.{ .storage = @ptrCast(&renewed.buffer), .columns = &renewed.view },
        } else null,
        .mark_target = &.{ .storage = @ptrCast(&marks.buffer), .columns = &marks.view },
        .read_target = if (function.record_reads) &.{ .storage = @ptrCast(&reads.buffer), .columns = &reads.view } else null,
    };

    zx.columns.invoke(publishing.executeValue, owner, &input_rows) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.debug.panic("demand publication failed: {s}", .{@errorName(err)}),
    };

    if (result.grew) function.growth.* = .{ .normalized = normalized.rows(), .renewed = renewed.rows() };

    return .{ .marks = marks.rows(), .changed = result.changed, .reads = reads.rows() };
}
