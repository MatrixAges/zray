const std = @import("std");
const memory = @import("memory");
const rules = @import("pkgs_source");
const Index = @This();
pub const Release = struct { version: []const u8, archive: []const u8, sha256: []const u8 };
pub const Package = struct { name: []const u8, versions: []const Release };

format_version: u32,
packages: []const Package,
pub fn parse(allocator: std.mem.Allocator, source: []const u8) !std.json.Parsed(Index) {
    const parsed = try std.json.parseFromSlice(Index, allocator, source, .{ .allocate = .alloc_always });

    errdefer parsed.deinit();

    try parsed.value.validate();

    return parsed;
}

pub fn validate(self: Index) !void {
    const names = memory.borrowTextColumn("name", self.packages);
    const versions = memory.borrowListColumn([]const u8, "versions", "version", self.packages);
    const archives = memory.borrowListColumn([]const u8, "versions", "archive", self.packages);
    const digests = memory.borrowListColumn([]const u8, "versions", "sha256", self.packages);
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const status = rules.index_validate.executeIn(empty.allocator(), &.{
        .format = self.format_version,
        .count = self.packages.len,
        .limit = std.math.maxInt(usize),
        .names = @ptrCast(&names),
        .versions = @ptrCast(&versions),
        .archives = @ptrCast(&archives),
        .digests = @ptrCast(&digests),
    }) catch unreachable;

    switch (status) {
        .Valid => {},
        .UnsupportedIndexVersion => return error.UnsupportedIndexVersion,
        .InvalidPackageName => return error.InvalidPackageName,
        .PackageHasNoVersions => return error.PackageHasNoVersions,
        .DuplicatePackage => return error.DuplicatePackage,
        .DuplicatePackageVersion => return error.DuplicatePackageVersion,
        .InvalidArchiveSource => return error.InvalidArchiveSource,
        .InvalidArchiveDigest => return error.InvalidArchiveDigest,
        .InvalidVersion => return error.InvalidVersion,
        .Overflow => return error.Overflow,
        .InvalidRange => unreachable,
    }
}

pub fn select(self: Index, package_name: []const u8, requirement: []const u8) !?Release {
    const names = memory.borrowTextColumn("name", self.packages);
    const versions = memory.borrowListColumn([]const u8, "versions", "version", self.packages);
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const chosen = rules.index_select.executeValue(empty.allocator(), .{
        .name = package_name,
        .range = requirement,
        .count = self.packages.len,
        .limit = std.math.maxInt(usize),
        .names = @ptrCast(&names),
        .versions = @ptrCast(&versions),
    }) catch unreachable;

    switch (chosen.status) {
        .Valid => return if (chosen.found) self.packages[@intCast(chosen.package)].versions[@intCast(chosen.release)] else null,
        .InvalidRange => return error.InvalidRange,
        .InvalidVersion => return error.InvalidVersion,
        .Overflow => return error.Overflow,
        else => unreachable,
    }
}
