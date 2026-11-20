pub const state = @import("publication_host").effects.state;
pub const Error = error{SourceLoadFailure};

pub const Failure = struct {
    value: ?anyerror = null,
    pub fn save(self: *Failure, err: anyerror) Error {
        self.value = err;

        return error.SourceLoadFailure;
    }
    pub fn unwrap(self: Failure, err: anyerror) anyerror {
        return if (err == error.SourceLoadFailure) self.value.? else err;
    }
};
