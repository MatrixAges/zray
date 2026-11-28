const std = @import("std");
const Text = @import("../../sources/text.zig");
const state = @import("state.zig");
const State = state.State;
const Error = state.effects.Error;
const FileRead = state.FileRead;
const PhysicalResolution = @import("cli_abi").layouts.@"zig:rx_collection_host".PhysicalResolution;

pub fn selectCollectionPath(handle: *const anyopaque, row: u64) Error!?[]const u8 {
    const self = State.get(handle);
    const allocator = self.allocator;
    const root = self.project.root_dir;
    const options = self.options;

    if (row >= self.queue.items.len) return null;

    _ = self.reference_memory.reset(.retain_capacity);

    const requested = self.queue.items[@intCast(row)];
    const candidate = std.fs.path.resolve(allocator, &.{ root, requested }) catch |err| return self.failure.save(err);
    const absolute = if (std.mem.endsWith(u8, candidate, ".zx")) @import("../../sources/module_path.zig").select(options.io, allocator, candidate, options.inputs) catch |err| return self.failure.save(err) else candidate;
    const path = std.fs.path.relative(allocator, root, null, root, absolute) catch |err| return self.failure.save(err);

    self.file = .{ .absolute = absolute, .path = path };

    return path;
}

pub fn resolveCollectionPhysicalPath(handle: *const anyopaque) Error!*const PhysicalResolution {
    const self = State.get(handle);
    const options = self.options;
    const absolute = self.file.absolute;

    if (options.inputs) |inputs| inputs.add(options.io, absolute) catch |err| return self.failure.save(err);

    self.file.real = std.Io.Dir.cwd().realPathFileAlloc(options.io, absolute, self.allocator) catch |err| {
        const problem = try self.fileUnavailable(err);

        self.physical_view = .{
            .availability = problem.availability,
            .real = "",
            .relative = "",
            .problem = problem.problem,
        };

        return &self.physical_view;
    };

    const relative = std.fs.path.relative(self.allocator, self.physical_root, null, self.physical_root, self.file.real) catch |err| return self.failure.save(err);

    self.physical_view = .{
        .availability = .Ready,
        .real = self.file.real,
        .relative = relative,
        .problem = "",
    };

    return &self.physical_view;
}

pub fn readCollectionFile(handle: *const anyopaque, retained: bool) Error!*const FileRead {
    const self = State.get(handle);
    const options = self.options;
    const allocator = if (retained) options.retained_source_allocator orelse self.allocator else self.allocator;
    const documents = if (retained) options.texts else null;
    const absolute = self.file.absolute;

    const text = Text.read(options.io, allocator, absolute, documents) catch |err| {
        self.file_read = try self.fileUnavailable(err);

        return &self.file_read;
    };

    if (text.fresh) if (options.inputs) |inputs| inputs.record(options.io, absolute, text.bytes) catch |err| return self.failure.save(err);

    self.file.text = text;
    self.file.documents = documents;
    self.file_read = .{ .availability = .Ready, .problem = "" };

    return &self.file_read;
}

pub fn writeCollectionDiagnostic(handle: *const anyopaque, message: []const u8) Error!void {
    const self = State.get(handle);

    self.options.writer.print("{s}: {s}\n", .{ self.file.path, message }) catch |err| return self.failure.save(err);
}
