const ir = @import("zx").ir;
const compare = @import("frontend").compare_ir;
const Finished = @import("../finished.zig");

pub const Range = struct {
    earlier: *const ir.FunctionTable,
    current: *const ir.FunctionStorage,
    first: usize,
    end: usize,
};

pub const Link = struct {
    earlier: *const Finished,
    current: *const Finished,
    row: usize,
};

pub fn matchHistoryLink(handle: *const anyopaque) bool {
    const link: *const Link = @ptrCast(@alignCast(handle));

    return @import("linked.zig").equal(link.current, link.earlier, link.row);
}

pub fn matchHistoryHeaders(handle: *const anyopaque) bool {
    const range: *const Range = @ptrCast(@alignCast(handle));
    const current = range.current.view();

    return compare.headers(range.earlier, &current, range.first, range.end);
}

pub fn matchHistoryBodies(handle: *const anyopaque) bool {
    const range: *const Range = @ptrCast(@alignCast(handle));
    const current = range.current.view();

    return compare.bodies(range.earlier, &current, range.first, range.end);
}
