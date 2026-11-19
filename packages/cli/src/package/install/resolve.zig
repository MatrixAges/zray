const std = @import("std");
const pkgs = @import("pkgs");
const Lock = pkgs.Lock;
const Manifest = @import("../manifest/model.zig").Manifest;
const model = @import("model.zig");

const Declarations = struct {
    dependencies: @FieldType(Manifest, "dependencies"),
    dev_dependencies: @FieldType(Manifest, "dev_dependencies"),
    fn borrow(manifest: *const Manifest) Declarations {
        return .{ .dependencies = manifest.dependencies, .dev_dependencies = manifest.dev_dependencies };
    }
};

const Self = @This();

pub const Options = struct { root: []const u8, cache: []const u8, source_base: []const u8, offline: bool };

io: std.Io,
allocator: std.mem.Allocator,
options: Options,
packages: std.ArrayList(Lock.Package) = .empty,
archive_declarations: std.ArrayList(Declarations) = .empty,
paths: std.ArrayList([]const u8) = .empty,
archives: pkgs.install.Archives,
pub fn resolve(io: std.Io, allocator: std.mem.Allocator, members: []const @import("../workspace.zig").Package, index: pkgs.Index, options: Options) !model.Prepared {
    var self: Self = .{ .io = io, .allocator = allocator, .options = options, .archives = .{ .table = .{ .allocator = allocator } } };

    defer self.archives.table.deinit();

    try self.packages.ensureTotalCapacity(allocator, members.len);
    try self.paths.ensureTotalCapacity(allocator, members.len);

    for (members) |member| {
        const path = try std.fs.path.resolve(allocator, &.{ options.root, member.path });

        self.packages.appendAssumeCapacity(.{ .name = member.manifest.name, .version = member.manifest.version, .source = .{ .workspace = member.path }, .dependencies = &.{} });
        self.paths.appendAssumeCapacity(try std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator));
    }

    const resolver = pkgs.install.Resolver.init(members, index);
    var owner: usize = 0;
    var edge_count: usize = 0;

    while (owner < self.packages.items.len) : (owner += 1) {
        const path = if (owner < members.len) members[owner].path else null;
        var dependencies: pkgs.install.Dependencies = undefined;
        const declarations = if (path != null) Declarations.borrow(&members[owner].manifest) else self.archive_declarations.items[owner - members.len];

        dependencies.init(declarations);

        while (try dependencies.advance(allocator, &resolver, path, Lock.maximum_dependencies - edge_count)) |pending| {
            dependencies.accept(try self.external(members.len, pending.name, pending.release));
        }

        const rows = dependencies.output.rows();

        self.packages.items[owner].dependencies = rows;
        edge_count += rows.len;
    }

    const lock: Lock = .{ .format_version = 1, .packages = try self.packages.toOwnedSlice(allocator) };

    try lock.validate(allocator);

    return .{ .lock = lock, .paths = try self.paths.toOwnedSlice(allocator) };
}

fn external(self: *Self, first: usize, name: []const u8, release: pkgs.Index.Release) !usize {
    const allocator = self.allocator;
    var spelling: [std.crypto.hash.sha2.Sha256.digest_length * 2]u8 = undefined;
    const key = std.ascii.lowerString(&spelling, release.sha256);
    const plan = try self.archives.plan(self.packages.items, first, key, name, release);

    const source = switch (plan) {
        .existing => |row| return row,
        .remote => release.archive,
        .local => source: {
            const absolute = try std.fs.path.resolve(allocator, &.{ self.options.source_base, release.archive });
            const relative = try std.fs.path.relative(allocator, self.options.root, null, self.options.root, absolute);

            std.mem.replaceScalar(u8, relative, '\\', '/');

            break :source relative;
        },
    };

    const digest = if (std.mem.eql(u8, key, release.sha256)) release.sha256 else try allocator.dupe(u8, key);
    const path = try @import("../store.zig").prepare(self.io, allocator, .{ .version = release.version, .archive = source, .sha256 = digest }, self.options.root, self.options.cache, self.options.offline);
    const data = try model.read(self.io, allocator, path, null);

    try pkgs.install.verify(name, release.version, &data);

    const target = self.packages.items.len;

    try self.packages.append(allocator, .{ .name = data.name, .version = data.version, .source = .{ .archive = .{ .archive = source, .sha256 = digest } }, .dependencies = &.{} });
    try self.paths.append(allocator, try std.Io.Dir.cwd().realPathFileAlloc(self.io, path, allocator));
    try self.archive_declarations.append(allocator, Declarations.borrow(&data));

    return target;
}
