const std = @import("std");
const Inputs = @import("watch_inputs").Inputs;
const inventory = @import("../inventory.zig");
const effects = @import("../../publication/effects.zig");
const Verification = @import("../../publication/verification.zig");
const output = @import("../../watch/output.zig");
const rule = @import("cli_source").library_retirement_plan;
const memory = @import("zx").memory;
const history = .{ .paths = "path", .digests = "sha256" };
const Error = effects.Error;
const StoreState = std.meta.Child(@FieldType(rule.zx_pending, "store_0"));

const StoreHost = struct {
    store_0: *StoreState,
    pub fn commit(self: *StoreHost, pending: anytype) error{}!void {
        if (pending.store_0) |next| self.store_0.* = next;
    }
};

pub fn prepareRetirement(allocator: std.mem.Allocator, handle: *const anyopaque, destination: []const u8, managed: []const []const u8) Error![]const []const u8 {
    const self = effects.state(Verification, handle);

    return retired(self.io, allocator, self.allocator, destination, managed, self.inputs) catch |err| self.failure.save(err);
}

fn retired(io: std.Io, allocator: std.mem.Allocator, backing: std.mem.Allocator, directory: []const u8, current: []const []const u8, inputs: *Inputs) ![]const []const u8 {
    var previous = (try inventory.read(io, backing, directory)) orelse return &.{};

    defer previous.deinit();

    var arena = std.heap.ArenaAllocator.init(backing);

    defer arena.deinit();

    const scratch = arena.allocator();
    const physical_root = try std.Io.Dir.cwd().realPathFileAlloc(io, directory, scratch);
    const managed = previous.value.managed_files;
    const borrowed = memory.borrowReadFields(history, managed orelse previous.value.bundled_files);
    const observed = try output.collectPaths(scratch, inputs);
    var kept: StoreState = &.{ .paths = &.{} };
    var host: StoreHost = .{ .store_0 = &kept };

    const raw = try rule.execute(&arena, &.{
        .directory = directory,
        .physical_root = physical_root,
        .managed = current,
        .observed = &.{
            .cwd = inputs.cwd,
            .logical = observed.logical,
            .physical = observed.physical,
        },
        .previous = &.{
            .paths = @ptrCast(borrowed.column("paths")),
            .digests = @ptrCast(borrowed.column("digests")),
            .count = borrowed.count,
            .native_only = managed == null,
        },
        .separator = std.fs.path.sep,
    }, &host, io);

    const status = if (@typeInfo(@TypeOf(raw)) == .pointer) raw.* else raw;

    switch (status) {
        .Ready => {},
        .InvalidInventory => return error.InvalidLibraryInventory,
        .Modified => return error.LibraryResourceModified,
        .OutsideOutput => return error.LibraryResourceOutsideOutput,
        .Overlap => return error.OutputOverlapsInput,
        .MissingParent => return error.FileNotFound,
    }

    const paths = try allocator.alloc([]const u8, kept.paths.len);
    var copied: usize = 0;

    errdefer {
        for (paths[0..copied]) |path| allocator.free(path);

        allocator.free(paths);
    }

    for (kept.paths, 0..) |path, index| {
        paths[index] = try allocator.dupe(u8, path);
        copied += 1;
    }

    return paths;
}

pub fn digestPublishedFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const hash = try inventory.digest(io, .cwd(), path);
    const hex = std.fmt.bytesToHex(hash, .lower);

    return allocator.dupe(u8, &hex);
}
