const Build = @import("../../build.zig");
const registration = @import("watch_inputs").observation.registration;
const Error = @import("../../sources/effects.zig").Error;

pub fn previousBackendPaths(handle: *const anyopaque) []const []const u8 {
    return Build.State.get(handle).context.watch.?.previous_backend;
}

pub fn hasBackendObservation(handle: *const anyopaque, path: []const u8) bool {
    return Build.State.get(handle).context.watch.?.inputs.entries.contains(path);
}

pub fn preloadBackendPath(handle: *const anyopaque, path: []const u8) Error!void {
    const self = Build.State.get(handle);
    const watch = self.context.watch.?;

    watch.preloaded.append(self.context.allocator, path) catch |err| return self.failure.save(err);

    const entry = if (registration.add(watch.inputs, self.context.io, path, false)) |added|
        added.entry

    else |err| failed: {
        if (err == error.OutOfMemory) return self.failure.save(err);

        break :failed watch.inputs.entries.getPtr(path) orelse return;
    };

    entry.backend_preloaded = true;
}

pub fn preloadedBackendPaths(handle: *const anyopaque) []const []const u8 {
    return Build.State.get(handle).context.watch.?.preloaded.items;
}

pub fn expireBackendPath(handle: *const anyopaque, path: []const u8) void {
    const entries = &Build.State.get(handle).context.watch.?.inputs.entries;
    const entry = entries.getPtr(path) orelse return;

    if (entry.backend_preloaded) _ = entries.remove(path);
}

pub fn publishBackendPaths(handle: *const anyopaque) void {
    const self = Build.State.get(handle);

    self.context.watch.?.backend_paths = self.observed.?.input_paths;
}
