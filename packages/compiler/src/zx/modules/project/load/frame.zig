const Error = error{ InvalidSource, OutOfMemory };

const Status = enum(u8) {
    ready,
    descend,
    invalid_source,
    out_of_memory,
    fn check(self: Status) Error!void {
        switch (self) {
            .ready, .descend => {},
            .invalid_source => return error.InvalidSource,
            .out_of_memory => return error.OutOfMemory,
        }
    }
};

extern fn zxcProjectFrameOpen(project: *const anyopaque, row: u64) Status;
extern fn zxcProjectFrameSnapshot(project: *const anyopaque, target: *[4]u64) void;
extern fn zxcProjectFrameResume(project: *const anyopaque, row: u64, child: u64, signature: bool) Status;
extern fn zxcProjectFrameVisit(project: *const anyopaque, row: u64, signature: bool, child: *u64) Status;
extern fn zxcProjectFramePublish(project: *const anyopaque, signature: bool) Status;
extern fn zxcProjectFrameClose(project: *const anyopaque) bool;

pub fn open(project: *const anyopaque, row: u64) Error!void {
    try zxcProjectFrameOpen(project, row).check();
}

pub fn snapshot(project: *const anyopaque, target: *const anyopaque) void {
    const items: *const []u64 = @ptrCast(@alignCast(target));

    zxcProjectFrameSnapshot(project, items.*[0..4]);
}

pub fn resumeImport(project: *const anyopaque, row: u64, child: u64, signature: bool) Error!void {
    try zxcProjectFrameResume(project, row, child, signature).check();
}

pub fn visit(project: *const anyopaque, row: u64, signature: bool) Error!?u64 {
    var child: u64 = undefined;
    const status = zxcProjectFrameVisit(project, row, signature, &child);

    try status.check();

    return if (status == .descend) child else null;
}

pub fn publishSignature(project: *const anyopaque) Error!void {
    try zxcProjectFramePublish(project, true).check();
}

pub fn publishBody(project: *const anyopaque) Error!void {
    try zxcProjectFramePublish(project, false).check();
}

pub const close = zxcProjectFrameClose;
