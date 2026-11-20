const std = @import("std");
const paths = @import("publication_host").paths;
const resources = @import("resources.zig");
const storage = @import("storage.zig");
const Context = storage.Context;
const Error = storage.Error;

pub fn openCollection(handle: *const anyopaque) Error!void {
    const self = Context.get(handle);

    if (self.entry) |path| if (self.inputs) |inputs| inputs.add(self.io, path) catch |err| return self.fail(err);

    self.canonical_root = std.Io.Dir.cwd().realPathFileAlloc(self.io, self.root, self.allocator) catch |err| return self.fail(err);
}

pub fn entryPath(handle: *const anyopaque) ?[]const u8 {
    return Context.get(handle).entry;
}

pub fn readBundle(handle: *const anyopaque, path: []const u8) Error![]const []const u8 {
    const self = Context.get(handle);
    const absolute = referencedPath(self.allocator, self.root, self.root, path) catch |err| return self.fail(err);

    checkPhysical(self, absolute) catch |err| return self.fail(err);

    return resources.files(self.io, self.allocator, absolute, self.inputs) catch |err| return self.fail(err);
}

pub fn enqueue(handle: *const anyopaque, path: []const u8, source: bool) Error!void {
    const self = Context.get(handle);

    self.pending.append(self.allocator, .{
        .path = path,
        .kind = if (source) .zig else .asset,
        .from = null,
    }) catch |err| return self.fail(err);
}

pub fn pendingCount(handle: *const anyopaque) u64 {
    return Context.get(handle).pending.items.len;
}

pub fn selectPending(handle: *const anyopaque, index: u64) Error!?bool {
    const self = Context.get(handle);

    self.current = self.pending.items[@intCast(index)];
    self.relative = relativePath(self.allocator, self.root, self.current.path) catch |err| return self.fail(err);
    self.previous = self.seen.getPtr(self.relative);

    return if (self.previous) |row| row.parsed else null;
}

pub fn sourcePending(handle: *const anyopaque) bool {
    return Context.get(handle).current.kind == .zig;
}

pub fn checkPending(handle: *const anyopaque) Error!void {
    const self = Context.get(handle);

    checkPhysical(self, self.current.path) catch |err| return self.fail(err);
}

fn checkPhysical(self: *Context, path: []const u8) !void {
    if (self.inputs) |inputs| try inputs.add(self.io, path);

    const canonical = try std.Io.Dir.cwd().realPathFileAlloc(self.io, path, self.allocator);

    _ = try relativePath(self.allocator, self.canonical_root, canonical);
}

pub fn readPending(handle: *const anyopaque) Error!void {
    const self = Context.get(handle);

    self.bytes = std.Io.Dir.cwd().readFileAllocOptions(self.io, self.current.path, self.allocator, .unlimited, .of(u8), 0) catch |err| return self.fail(err);
}

pub fn reusePending(handle: *const anyopaque) void {
    const self = Context.get(handle);

    self.bytes = self.sources.items[self.previous.?.index].bytes;
}

pub fn observePending(handle: *const anyopaque) Error!void {
    const self = Context.get(handle);

    if (self.inputs) |inputs| inputs.record(self.io, self.current.path, self.bytes) catch |err| return self.fail(err);
}

pub fn addPending(handle: *const anyopaque) Error!void {
    const self = Context.get(handle);

    self.seen.put(self.allocator, self.relative, .{ .index = self.sources.items.len, .parsed = self.current.kind == .zig }) catch |err| return self.fail(err);

    self.sources.append(self.allocator, .{
        .path = self.relative,
        .kind = self.current.kind,
        .bytes = self.bytes,
        .referenced_from = self.current.from,
    }) catch |err| return self.fail(err);
}

pub fn promotePending(handle: *const anyopaque) void {
    const self = Context.get(handle);
    const row = self.previous.?;

    self.sources.items[row.index].kind = .zig;
    row.parsed = true;
}

pub fn referenceCount(handle: *const anyopaque) u64 {
    return Context.get(handle).references.items.len;
}

pub fn enqueueReference(handle: *const anyopaque, index: u64) Error!void {
    const self = Context.get(handle);
    const reference = self.references.items[@intCast(index)];
    const parent = std.fs.path.dirname(self.current.path).?;
    const path = referencedPath(self.allocator, self.root, parent, reference.path) catch |err| return self.fail(err);

    self.pending.append(self.allocator, .{ .path = path, .kind = reference.kind, .from = self.relative }) catch |err| return self.fail(err);
}

pub fn referencedPath(allocator: std.mem.Allocator, root: []const u8, parent: []const u8, path: []const u8) ![]const u8 {
    if (!paths.validReference(path)) return error.InvalidNativeResourcePath;

    const absolute = try std.fs.path.resolve(allocator, &.{ parent, path });
    _ = try relativePath(allocator, root, absolute);

    return absolute;
}

fn relativePath(allocator: std.mem.Allocator, root: []const u8, absolute: []const u8) ![]const u8 {
    const relative = try std.fs.path.relative(allocator, root, null, root, absolute);

    if (!paths.within(relative)) return error.NativeResourceOutsideModule;

    return relative;
}
