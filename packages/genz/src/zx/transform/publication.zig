const std = @import("std");
const node = @import("../../node.zig");
const blocks = @import("../../node/blocks.zig");
const view = @import("../../node/view.zig");
const rows = @import("../../node/import_rows.zig");
const Lower = @import("../lower.zig");
const evaluation = @import("../expressions/evaluate.zig");
const Predicate = std.meta.Child(@import("generated_predicate_emit").Output);
const Reduce = std.meta.Child(@import("generated_reduce_emit").Output);
const Columns = @FieldType(Predicate, "stop");
const ReduceResult = view.Joined(std.meta.Child(@FieldType(Reduce, "outer")), std.meta.Child(@FieldType(Reduce, "variables")));
const Error = Lower.Error;
const Api = evaluation.Api;

pub const Fragments = struct {
    prelude: ?Columns = null,
    element: node.Block,
    step: Columns,
    remainder: ?node.Block = null,
    outer: node.Block,
    result: union(enum) { statements: Columns, reduce: *const ReduceResult },
};

const Frame = struct {
    lowering: *Lower,
    fragments: *const Fragments,
    fn borrow(handle: *const anyopaque) *const Frame {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn append(self: *Lower, fragments: *const Fragments) Error!void {
    const entry = @import("generated_publish_transform_fragments");
    const frame: Frame = .{ .lowering = self, .fragments = fragments };

    return evaluation.execute(entry, &.{
        .target = @ptrCast(&frame),
        .prelude = fragments.prelude != null,
        .remainder = fragments.remainder != null,
    });
}

pub fn appendTransformStatements(handle: *const anyopaque, part: Api.TransformStatements) Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const target = &self.builder.nodes.statements;
    const fragments = frame.fragments;

    if (part == .Result and fragments.result == .reduce) {
        return rows.appendBorrowed(self.allocator, target, fragments.result.reduce) catch |err| return failure(err);
    }

    const source = switch (part) {
        .Prelude => fragments.prelude.?,
        .Step => fragments.step,
        .Result => fragments.result.statements,
    };

    if (fragments.result == .reduce) {
        return rows.appendBorrowed(self.allocator, target, source) catch |err| return failure(err);
    }

    return rows.appendBorrowingText(self.allocator, target, source) catch |err| return failure(err);
}

pub fn appendTransformSpan(handle: *const anyopaque, part: Api.TransformSpan) Error!void {
    const frame = Frame.borrow(handle);
    const fragments = frame.fragments;

    const span = switch (part) {
        .Element => fragments.element,
        .Remainder => fragments.remainder.?,
        .Outer => fragments.outer,
    };

    return blocks.appendAtTail(frame.lowering.allocator, frame.lowering.builder.nodes, span);
}

fn failure(err: rows.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidAst => unreachable,
    };
}
