pub extern fn borrowArtifactBinding(frame: *const anyopaque, index: u64) void;
extern fn zxcPublishArtifactBody(frame: *const anyopaque, index: u64, append: bool, reject_store: bool) u8;

pub fn publishArtifactBody(frame: *const anyopaque, index: u64, append: bool, reject_store: bool) error{ OutOfMemory, InvalidModule }!void {
    return switch (zxcPublishArtifactBody(frame, index, append, reject_store)) {
        0 => {},
        1 => error.OutOfMemory,
        2 => error.InvalidModule,
        else => unreachable,
    };
}
