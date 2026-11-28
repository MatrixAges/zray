const std = @import("std");
const watch = @import("watch_inputs");
const Error = error{BackendInputFailure};

pub const Context = struct {
    io: std.Io,
    inputs: *watch.Inputs,
    failure: ?anyerror = null,
    fn get(handle: *anyopaque) *Context {
        return @ptrCast(@alignCast(handle));
    }
    fn fail(self: *Context, err: anyerror) Error {
        self.failure = err;

        return error.BackendInputFailure;
    }
};

pub fn registerPath(handle: *anyopaque, path: []const u8) Error!bool {
    const self = Context.get(handle);
    const addition = watch.observation.registration.add(self.inputs, self.io, path, false) catch |err| return self.fail(err);

    addition.entry.backend_preloaded = false;

    return addition.inserted;
}
