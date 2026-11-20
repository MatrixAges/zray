const std = @import("std");
const Text = @import("../../sources/text.zig");
const state = @import("state.zig");
const State = state.State;
const Error = state.effects.Error;
const Availability = state.Availability;

pub fn selectCollectionPath(handle: *const anyopaque, row: u64) Error![]const u8 {
    const self = State.get(handle);
    const allocator = self.allocator;
    const root = self.project.root_dir;
    const options = self.options;
    _ = self.reference_memory.reset(.retain_capacity);

    const requested = self.queue.items[@intCast(row)];
    const candidate = std.fs.path.resolve(allocator, &.{ root, requested }) catch |err| return self.failure.save(err);
    const absolute = if (std.mem.endsWith(u8, candidate, ".zx")) @import("../../sources/module_path.zig").select(options.io, allocator, candidate, options.inputs) catch |err| return self.failure.save(err) else candidate;
    const path = std.fs.path.relative(allocator, root, null, root, absolute) catch |err| return self.failure.save(err);

    self.file = .{ .absolute = absolute, .path = path };

    return path;
}

pub fn resolveCollectionPhysicalPath(handle: *const anyopaque) Error!Availability {
    const self = State.get(handle);
    const options = self.options;
    const absolute = self.file.absolute;

    if (options.inputs) |inputs| inputs.add(options.io, absolute) catch |err| return self.failure.save(err);

    self.file.real = std.Io.Dir.cwd().realPathFileAlloc(options.io, absolute, self.allocator) catch |err| return self.fileUnavailable(err);

    return .Ready;
}

pub fn collectionPhysicalRelative(handle: *const anyopaque) Error![]const u8 {
    const self = State.get(handle);

    return std.fs.path.relative(self.allocator, self.physical_root, null, self.physical_root, self.file.real) catch |err| return self.failure.save(err);
}

pub fn previousCollectionPath(handle: *const anyopaque) ?[]const u8 {
    const self = State.get(handle);

    return self.physical.get(self.file.real);
}

pub fn registerCollectionPhysicalPath(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.physical.put(self.allocator, self.file.real, self.file.path) catch |err| return self.failure.save(err);
}

pub fn readCollectionFile(handle: *const anyopaque, retained: bool) Error!Availability {
    const self = State.get(handle);
    const options = self.options;
    const allocator = if (retained) options.retained_source_allocator orelse self.allocator else self.allocator;
    const documents = if (retained) options.texts else null;
    const absolute = self.file.absolute;
    const text = Text.read(options.io, allocator, absolute, documents) catch |err| return self.fileUnavailable(err);

    if (text.fresh) if (options.inputs) |inputs| inputs.record(options.io, absolute, text.bytes) catch |err| return self.failure.save(err);

    self.file.text = text;
    self.file.documents = documents;

    return .Ready;
}

pub fn reportCollectionFileFailure(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.options.writer.print("{s}: {s}\n", .{ self.file.path, @errorName(self.file.problem) }) catch |err| return self.failure.save(err);
}

pub fn reportCollectionEscape(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.options.writer.print("{s}: physical module file escapes the project root\n", .{self.file.path}) catch |err| return self.failure.save(err);
}

pub fn reportCollectionAlias(handle: *const anyopaque, previous: []const u8) Error!void {
    const self = State.get(handle);

    self.options.writer.print("{s}: physical module file is already registered as {s}\n", .{ self.file.path, previous }) catch |err| return self.failure.save(err);
}
