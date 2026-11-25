const std = @import("std");
const Inputs = @import("watch_inputs").Inputs;
const inventory = @import("../inventory.zig");
const effects = @import("../../publication/effects.zig");
const output = @import("../../watch/output.zig");
const rule = @import("cli_source").library_retirement_plan;
const zx = @import("zx");
const abi = @import("publication_abi");
const FileKind = abi.native.@"zig:publication_host".RetirementFile;
const Path = abi.layouts.@"zig:publication_host".RetirementPath;
const Input = std.meta.Child(rule.Input);
const Entries = std.meta.Child(@FieldType(Input, "previous"));
const history = .{ .paths = "path", .digests = "sha256" };
const Error = effects.Error;
const Sha256 = std.crypto.hash.sha2.Sha256;

const Plan = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    backing: std.mem.Allocator,
    directory: []const u8,
    current: []const inventory.File,
    inputs: *Inputs,
    planning: std.heap.ArenaAllocator,
    row: std.heap.ArenaAllocator,
    failure: effects.Failure = .{},
    previous: ?std.json.Parsed(inventory.Inventory) = null,
    physical_root: []const u8 = undefined,
    targets: [][]const u8 = &.{},
    names: std.StringHashMapUnmanaged(void) = .empty,
    paths: std.ArrayList([]const u8) = .empty,
    entries: Entries = undefined,
    borrowed: zx.memory.ReadFields(history) = undefined,
    spelling: Path = undefined,
    physical: Path = undefined,
    hex: [Sha256.digest_length * 2]u8 = undefined,
};

pub fn retired(io: std.Io, allocator: std.mem.Allocator, backing: std.mem.Allocator, directory: []const u8, current: []const inventory.File, inputs: *Inputs) ![]const []const u8 {
    var plan: Plan = .{
        .io = io,
        .allocator = allocator,
        .backing = backing,
        .directory = directory,
        .current = current,
        .inputs = inputs,
        .planning = .init(backing),
        .row = .init(backing),
    };

    defer plan.planning.deinit();
    defer plan.row.deinit();
    defer if (plan.previous) |*previous| previous.deinit();
    errdefer plan.paths.deinit(allocator);

    const state = &plan;

    const status = rule.executeIn(allocator, &.{
        .retirement = @ptrCast(&state),
        .previous = &plan.entries,
        .separator = std.fs.path.sep,
    }) catch |err| return plan.failure.unwrap(err);

    return switch (status) {
        .Ready => plan.paths.items,
        .InvalidInventory => error.InvalidLibraryInventory,
        .Modified => error.LibraryResourceModified,
        .OutsideOutput => error.LibraryResourceOutsideOutput,
    };
}

pub fn readRetirement(handle: *const anyopaque) Error!bool {
    const self = effects.state(Plan, handle);

    self.previous = inventory.read(self.io, self.backing, self.directory) catch |err| return self.failure.save(err);

    const previous = self.previous orelse return false;
    const managed = previous.value.managed_files;

    self.borrowed = zx.memory.borrowReadFields(history, managed orelse previous.value.bundled_files);

    self.entries = .{
        .paths = @ptrCast(self.borrowed.column("paths")),
        .digests = @ptrCast(self.borrowed.column("digests")),
        .count = self.borrowed.count,
        .native_only = managed == null,
    };

    return true;
}

pub fn reserveTargets(handle: *const anyopaque) Error!void {
    const self = effects.state(Plan, handle);
    const memory = self.planning.allocator();
    self.physical_root = std.Io.Dir.cwd().realPathFileAlloc(self.io, self.directory, memory) catch |err| return self.failure.save(err);
    self.targets = memory.alloc([]const u8, self.current.len) catch |err| return self.failure.save(err);

    self.names.ensureTotalCapacity(memory, @intCast(self.current.len)) catch |err| return self.failure.save(err);
}

pub fn retirementTargetCount(handle: *const anyopaque) u64 {
    return effects.state(Plan, handle).current.len;
}

pub fn registerRetirementTarget(handle: *const anyopaque, index: u64) Error!void {
    const self = effects.state(Plan, handle);
    const row: usize = @intCast(index);
    const path = std.fs.path.resolve(self.planning.allocator(), &.{ self.directory, self.current[row].path }) catch |err| return self.failure.save(err);

    self.targets[row] = path;

    self.names.putAssumeCapacity(path, {});
}

pub fn retirementTargets(handle: *const anyopaque) []const []const u8 {
    return effects.state(Plan, handle).targets;
}

pub fn retirementSpelling(handle: *const anyopaque, entry: []const u8) Error!*const Path {
    const self = effects.state(Plan, handle);

    _ = self.row.reset(.retain_capacity);

    const memory = self.row.allocator();
    const path = std.fs.path.resolve(memory, &.{ self.directory, entry }) catch |err| return self.failure.save(err);
    const relative = std.fs.path.relative(memory, self.directory, null, self.directory, path) catch |err| return self.failure.save(err);

    inventory.makePortable(relative);

    self.spelling = .{ .path = path, .relative = relative };

    return &self.spelling;
}

pub fn retirementSpellingMatches(handle: *const anyopaque, path: []const u8) bool {
    return effects.state(Plan, handle).names.contains(path);
}

pub fn retirementFileKind(handle: *const anyopaque, path: []const u8) Error!FileKind {
    const self = effects.state(Plan, handle);

    return kind(self.io, path) catch |err| return self.failure.save(err);
}

fn kind(io: std.Io, path: []const u8) !FileKind {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .Missing,
        else => return err,
    };

    return if (stat.kind == .file) .Regular else .Other;
}

pub fn retirementPhysical(handle: *const anyopaque, spelling: []const u8) Error!*const Path {
    const self = effects.state(Plan, handle);
    const memory = self.row.allocator();
    const path = std.Io.Dir.cwd().realPathFileAlloc(self.io, spelling, memory) catch |err| return self.failure.save(err);
    const relative = std.fs.path.relative(memory, self.physical_root, null, self.physical_root, path) catch |err| return self.failure.save(err);

    self.physical = .{ .path = path, .relative = relative };

    return &self.physical;
}

pub fn retirementPhysicalMatches(handle: *const anyopaque, target: []const u8, physical: []const u8) Error!bool {
    const self = effects.state(Plan, handle);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = std.Io.Dir.cwd().realPathFile(self.io, target, &buffer) catch |err| return self.failure.save(err);

    return std.mem.eql(u8, physical, buffer[0..length]);
}

pub fn checkRetirementInput(handle: *const anyopaque, path: []const u8) Error!void {
    const self = effects.state(Plan, handle);

    _ = output.check(self.io, self.row.allocator(), self.inputs, path) catch |err| return self.failure.save(err);
}

pub fn retirementDigest(handle: *const anyopaque, path: []const u8) Error![]const u8 {
    const self = effects.state(Plan, handle);
    const hash = inventory.digest(self.io, .cwd(), path) catch |err| return self.failure.save(err);

    self.hex = std.fmt.bytesToHex(hash, .lower);

    return &self.hex;
}

pub fn keepRetirement(handle: *const anyopaque, path: []const u8) Error!void {
    const self = effects.state(Plan, handle);
    const owned = self.allocator.dupe(u8, path) catch |err| return self.failure.save(err);

    self.paths.append(self.allocator, owned) catch |err| return self.failure.save(err);
}
