const Self = @This();
pub const Error = error{BootstrapOutput};

original: ?anyerror = null,
pub fn save(self: *Self, err: anyerror) Error {
    self.original = err;

    return error.BootstrapOutput;
}

pub fn restore(self: Self, err: anyerror) anyerror {
    return self.original orelse err;
}
