const zx = @import("zx");

pub fn errorSet(err: anyerror) zx.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidSource => error.InvalidSource,
        else => unreachable,
    };
}
