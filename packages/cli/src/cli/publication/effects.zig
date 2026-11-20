pub const Error = error{PublicationFailure};

pub const Failure = struct {
    value: ?anyerror = null,
    pub fn save(self: *Failure, err: anyerror) Error {
        self.value = err;

        return error.PublicationFailure;
    }
    pub fn unwrap(self: *const Failure, err: anyerror) anyerror {
        return if (err == error.PublicationFailure) self.value.? else err;
    }
};

pub fn borrow(comptime T: type, handle: *const anyopaque) *T {
    return @ptrCast(@alignCast(@constCast(handle)));
}

pub fn state(comptime T: type, handle: *const anyopaque) *T {
    // The ABI borrows the pointer itself. The state behind it stays writable.
    const reference: *const *T = @ptrCast(@alignCast(handle));

    return reference.*;
}
