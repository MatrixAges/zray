const std = @import("std");
const zx = @import("zx");
const Function = @import("../function.zig");
const Context = @import("context.zig");
const rows = @import("../row_output.zig");
const generated = @import("generated_uniqueness_function_demand");
const Input = std.meta.Child(generated.Input);
const Analysis = std.meta.Child(@FieldType(Input, "analysis"));
const Source = std.meta.Child(@FieldType(Analysis, "source"));
const Publication = std.meta.Child(@FieldType(Input, "targets"));
const Targets = rows.Target(Publication, "growth");

pub fn analyze(function: *Function, owner: std.mem.Allocator, restored_growth: bool) std.mem.Allocator.Error!Function.Demand {
    var borrowed: Context = undefined;

    borrowed.init(function);

    const source: Source = .{
        .kinds = function.slots.types.kinds,
        .exchange = &.{
            .return_allocations = function.summaries.return_allocations,
            .inputs = @ptrCast(&function.summaries.inputs),
            .outputs = @ptrCast(&function.summaries.outputs),
            .deferred = function.deferred,
        },
        .function_index = if (function.function) |index| @intCast(index) else null,
        .operations = @ptrCast(function.operations),
        .results = function.facts.results,
    };

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

    const scratch = function.allocator;
    var scope = zx.memory.ArenaScope{ .active = scratch };

    const input: Input = .{
        .analysis = &.{
            .context = &borrowed.descriptor,
            .repeated = function.facts.repeated.owner,
            .source = &source,
        },
        .targets = &.{
            .growth = &.{
                .normalized = &.{ .storage = @ptrCast(&normalized.buffer), .columns = &normalized.view },
                .renewed = &.{ .storage = @ptrCast(&renewed.buffer), .columns = &renewed.view },
            },
            .mark_target = &.{ .storage = @ptrCast(&marks.buffer), .columns = &marks.view },
            .read_target = if (function.record_reads) &.{ .storage = @ptrCast(&reads.buffer), .columns = &reads.view } else null,
        },
        .arenas = &.{ .scope = @ptrCast(&scope), .scratch = @ptrCast(&scratch), .owner = @ptrCast(&owner) },
        .restored_growth = restored_growth,
    };

    const result = zx.columns.invoke(generated.executeValue, scope.allocator(), &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.debug.panic("function demand failed: {s}", .{@errorName(err)}),
    };

    function.grew = function.grew or result.grew;

    if (result.retained_growth) function.growth.* = .{ .normalized = normalized.rows(), .renewed = renewed.rows() };

    return .{ .marks = marks.rows(), .changed = result.changed, .reads = reads.rows() };
}
