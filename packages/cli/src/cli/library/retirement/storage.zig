const std = @import("std");
const Inputs = @import("watch_inputs").Inputs;
const inventory = @import("../inventory.zig");
const effects = @import("../../publication/effects.zig");
const output = @import("../../watch/output.zig");
const paths = @import("../../native_sources/path.zig");
const rule = @import("cli_source").library_retirement_plan;
const FileKind = @import("publication_abi").native.@"zig:publication_host".RetirementFile;
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
    root: []const u8 = undefined,
    physical_root: []const u8 = undefined,
    targets: [][]const u8 = &.{},
    names: std.StringHashMapUnmanaged(void) = .empty,
    paths: std.ArrayList([]const u8) = .empty,
    selected: inventory.File = undefined,
    path: []const u8 = undefined,
    physical: []const u8 = undefined,
    hex: [Sha256.digest_length * 2]u8 = undefined,
    fn files(self: *const Plan) []const inventory.File {
        const previous = &self.previous.?.value;

        return previous.managed_files orelse previous.bundled_files;
    }
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
    const status = rule.executeIn(allocator, @ptrCast(&state)) catch |err| return plan.failure.unwrap(err);

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

    return self.previous != null;
}

pub fn reserveTargets(handle: *const anyopaque) Error!void {
    const self = effects.state(Plan, handle);
    const memory = self.planning.allocator();
    self.root = std.fs.path.resolve(memory, &.{self.directory}) catch |err| return self.failure.save(err);
    self.physical_root = std.Io.Dir.cwd().realPathFileAlloc(self.io, self.root, memory) catch |err| return self.failure.save(err);
    self.targets = memory.alloc([]const u8, self.current.len) catch |err| return self.failure.save(err);

    self.names.ensureTotalCapacity(memory, @intCast(self.current.len)) catch |err| return self.failure.save(err);
}

pub fn retirementTargetCount(handle: *const anyopaque) u64 {
    return effects.state(Plan, handle).current.len;
}

pub fn registerRetirementTarget(handle: *const anyopaque, index: u64) Error!void {
    const self = effects.state(Plan, handle);
    const row: usize = @intCast(index);
    const path = std.fs.path.resolve(self.planning.allocator(), &.{ self.root, self.current[row].path }) catch |err| return self.failure.save(err);

    self.targets[row] = path;

    self.names.putAssumeCapacity(path, {});
}

pub fn retirementOldCount(handle: *const anyopaque) u64 {
    return effects.state(Plan, handle).files().len;
}

pub fn retirementNativeOnly(handle: *const anyopaque) bool {
    return effects.state(Plan, handle).previous.?.value.managed_files == null;
}

pub fn selectRetirementRow(handle: *const anyopaque, index: u64) Error![]const u8 {
    const self = effects.state(Plan, handle);

    _ = self.row.reset(.retain_capacity);
    self.selected = self.files()[@intCast(index)];
    const memory = self.row.allocator();
    self.path = std.fs.path.resolve(memory, &.{ self.root, self.selected.path }) catch |err| return self.failure.save(err);
    const relative = std.fs.path.relative(memory, self.root, null, self.root, self.path) catch |err| return self.failure.save(err);

    inventory.makePortable(relative);

    return relative;
}

pub fn retirementSpellingMatches(handle: *const anyopaque) bool {
    const self = effects.state(Plan, handle);

    return self.names.contains(self.path);
}

pub fn retirementOldKind(handle: *const anyopaque) Error!FileKind {
    const self = effects.state(Plan, handle);

    return kind(self.io, self.path) catch |err| return self.failure.save(err);
}

pub fn retirementTargetKind(handle: *const anyopaque, index: u64) Error!FileKind {
    const self = effects.state(Plan, handle);

    return kind(self.io, self.targets[@intCast(index)]) catch |err| return self.failure.save(err);
}

fn kind(io: std.Io, path: []const u8) !FileKind {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .Missing,
        else => return err,
    };

    return if (stat.kind == .file) .Regular else .Other;
}

pub fn resolveRetirementRow(handle: *const anyopaque) Error!bool {
    const self = effects.state(Plan, handle);
    const memory = self.row.allocator();
    self.physical = std.Io.Dir.cwd().realPathFileAlloc(self.io, self.path, memory) catch |err| return self.failure.save(err);
    const relative = std.fs.path.relative(memory, self.physical_root, null, self.physical_root, self.physical) catch |err| return self.failure.save(err);

    return paths.within(relative);
}

pub fn retirementPhysicalMatches(handle: *const anyopaque, index: u64) Error!bool {
    const self = effects.state(Plan, handle);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = std.Io.Dir.cwd().realPathFile(self.io, self.targets[@intCast(index)], &buffer) catch |err| return self.failure.save(err);

    return std.mem.eql(u8, self.physical, buffer[0..length]);
}

pub fn checkRetirementInput(handle: *const anyopaque) Error!void {
    const self = effects.state(Plan, handle);

    _ = output.check(self.io, self.row.allocator(), self.inputs, self.path) catch |err| return self.failure.save(err);
}

pub fn retirementDigest(handle: *const anyopaque) Error![]const u8 {
    const self = effects.state(Plan, handle);
    const hash = inventory.digest(self.io, .cwd(), self.path) catch |err| return self.failure.save(err);

    self.hex = std.fmt.bytesToHex(hash, .lower);

    return &self.hex;
}

pub fn retirementExpectedDigest(handle: *const anyopaque) []const u8 {
    return effects.state(Plan, handle).selected.sha256;
}

pub fn keepRetirement(handle: *const anyopaque) Error!void {
    const self = effects.state(Plan, handle);
    const path = self.allocator.dupe(u8, self.path) catch |err| return self.failure.save(err);

    self.paths.append(self.allocator, path) catch |err| return self.failure.save(err);
}
