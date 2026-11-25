const std = @import("std");
const watch = @import("watch_inputs");
const protocol = @import("backend_protocol");
const Error = error{BackendInputFailure};

pub const Context = struct {
    io: std.Io,
    owned: std.mem.Allocator,
    inputs: *watch.Inputs,
    translations: []const protocol.Result,
    response: *const protocol.Result,
    batch: *const protocol.Result = undefined,
    paths: [][]const u8 = &.{},
    written: usize = 0,
    failure: ?anyerror = null,
    fn get(handle: *anyopaque) *Context {
        return @ptrCast(@alignCast(handle));
    }
    fn fail(self: *Context, err: anyerror) Error {
        self.failure = err;

        return error.BackendInputFailure;
    }
};

pub fn selectBatch(handle: *anyopaque, index: u64) u64 {
    const self = Context.get(handle);

    self.batch = if (index == self.translations.len) self.response else &self.translations[@intCast(index)];

    return self.batch.inputs.len;
}

pub fn completeBatch(handle: *anyopaque) bool {
    return Context.get(handle).batch.inputs_complete;
}

pub fn reserve(handle: *anyopaque, count: u64) Error!void {
    const self = Context.get(handle);
    const capacity = std.math.cast(usize, count) orelse return self.fail(error.OutOfMemory);

    self.paths = self.owned.alloc([]const u8, capacity) catch |err| return self.fail(err);
}

pub fn prefixAt(handle: *anyopaque, row: u64) u8 {
    const self = Context.get(handle);

    return @backingInt(self.batch.inputs[@intCast(row)].prefix);
}

pub fn registerPath(handle: *anyopaque, row: u64, root: []const u8) Error!bool {
    const self = Context.get(handle);
    const input = self.batch.inputs[@intCast(row)];
    const path = std.fs.path.resolve(self.owned, &.{ root, input.path }) catch |err| return self.fail(err);
    const addition = watch.observation.registration.add(self.inputs, self.io, path, false) catch |err| return self.fail(err);

    addition.entry.backend_preloaded = false;
    self.paths[self.written] = path;
    self.written += 1;

    return addition.inserted;
}
