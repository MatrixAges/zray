pub const Error = error{LibraryWorkflowFailure};
pub const state = @import("publication_host").effects.state;

pub const Failure = struct {
    value: ?anyerror = null,
    pub fn save(self: *Failure, err: anyerror) Error {
        self.value = err;

        return error.LibraryWorkflowFailure;
    }
    pub fn unwrap(self: Failure, err: anyerror) anyerror {
        return if (err == error.LibraryWorkflowFailure) self.value.? else err;
    }
};
