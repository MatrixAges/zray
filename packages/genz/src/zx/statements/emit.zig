const Lower = @import("../lower.zig");
const evaluation = @import("../expressions/evaluate.zig");
const rows = @import("../construction/publication.zig");

pub fn beginStatementStore(handle: *anyopaque, first: u64, count: u64, index: u64) Lower.Error!u64 {
    const self = evaluation.borrow(handle);

    const span = try @import("../store/begin.zig").lower(self, .{
        .control = self.program.body.control,
        .first = @intCast(first),
        .len = @intCast(count),
    }, @intCast(index));

    return rows.packSpan(span);
}

pub fn emitParallelStatement(handle: *anyopaque, statement: u64) Lower.Error!u64 {
    const self = evaluation.borrow(handle);
    const invocations = self.program.body.block().at(@intCast(statement)).parallel;
    const span = try @import("../parallel/root.zig").lower(self, invocations);

    return rows.packSpan(span);
}
