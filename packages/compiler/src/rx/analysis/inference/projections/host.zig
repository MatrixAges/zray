const zx = @import("zx");
const Graph = @import("../types.zig");
const Access = @import("../fields/access.zig");

fn graph(handle: *const anyopaque) *Graph {
    return @ptrCast(@alignCast(@constCast(handle)));
}

fn span(handle: *const anyopaque, row: u64) zx.Span {
    const spans: *const []const zx.Span = @ptrCast(@alignCast(handle));

    return spans.*[@intCast(row)];
}

pub fn registerProjectionType(handle: *const anyopaque, spans: *const anyopaque, row: u64, value: u32) zx.Error!u32 {
    return @backingInt(try graph(handle).known(@fromBackingInt(value), span(spans, row)));
}

pub fn mergeProjection(handle: *const anyopaque, spans: *const anyopaque, row: u64, left: u32, right: u32) zx.Error!void {
    try graph(handle).unify(@fromBackingInt(left), @fromBackingInt(right), span(spans, row));
}

pub fn rejectProjection(handle: *const anyopaque, spans: *const anyopaque, row: u64, message: []const u8) zx.Error!void {
    return graph(handle).reporter.fail(.type_mismatch, span(spans, row), message);
}

pub fn requireProjectionList(handle: *const anyopaque, spans: *const anyopaque, row: u64, target: u32) zx.Error!u32 {
    return @backingInt(try graph(handle).payload(@fromBackingInt(target), .list, span(spans, row)));
}

pub fn readOpenLength(handle: *const anyopaque, spans: *const anyopaque, row: u64, root: u32) zx.Error!u32 {
    return @backingInt(try Access.open(graph(handle), @fromBackingInt(root), Access.length_name, span(spans, row)));
}
