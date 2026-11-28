const std = @import("std");
const compiler = @import("compiler");
const source = compiler.input_snapshot;
const seed = @import("input_snapshot_seed.zig");
const seed_interfaces = compiler.source_inputs.interface_seed;
const collection = @import("source_collection.zig");
const manifest = @import("generation_manifest.zig");
const Files = @import("resident/files.zig");
const Self = @This();
const name = "input-snapshots";
const Root = struct { path: []const u8, entries: []const collection.Entry };
const Fact = source.Observation;

roots: []const Root,
facts: []const Fact,
context: []const u8,
path: []const u8,

fingerprint: ?[32]u8 = null,
/// Platform observations only: RX/ZX decides whether the previous snapshot vouches for these files.
pub fn prepare(io: std.Io, allocator: std.mem.Allocator, paths: std.mem.Allocator, files: *Files, digest: [32]u8, project: manifest.Project, text: []const u8, partitions: u32, cache: []const u8) !Self {
    const roots = try allocator.alloc(Root, project.roots.len);
    var facts: std.ArrayList(Fact) = .empty;

    for (project.roots, roots) |root, *target| {
        const entries = try collection.scan(io, allocator, paths, files, root.path, root.prefix, true);

        target.* = .{ .path = root.path, .entries = entries };

        for (entries) |entry| {
            const path = try std.fs.path.resolve(allocator, &.{ root.path, entry.relative });

            try facts.append(allocator, Fact.init(path, entry.path, entry.metadata.?));
        }
    }

    if (!try observeInterfaces(io, allocator, &facts, project.interfaces)) return .{ .roots = roots, .facts = &.{}, .context = "", .path = "" };
    try compiler.source_inputs.order.sort(Fact, files.gpa, facts.items);

    const here = try std.process.currentPathAlloc(io, allocator);
    const identity = compiler.input_fingerprint.snapshot(&digest, partitions, here, text);
    const context = try allocator.dupe(u8, &std.fmt.bytesToHex(identity, .lower));
    const path = try std.fs.path.join(allocator, &.{ cache, name, context });
    const fingerprint = try reuseSaved(io, files.gpa, path, context, facts.items);

    return .{ .roots = roots, .facts = facts.items, .context = context, .path = path, .fingerprint = fingerprint };
}

fn reuseSaved(io: std.Io, workspace: std.mem.Allocator, path: []const u8, context: []const u8, facts: []const Fact) !?[32]u8 {
    var scratch = std.heap.ArenaAllocator.init(workspace);

    defer scratch.deinit();

    const allocator = scratch.allocator();
    const recorded = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(source.storage_limit)) catch return null;
    const payload = try source.open(allocator, recorded) orelse return null;
    const now = source.timestamp(std.Io.Timestamp.now(io, .real).nanoseconds);

    if (comptime source.binary_records) return source.records.reuse(payload, context, facts, now);

    return seed.reuse(allocator, payload, context, facts, now);
}

pub fn loadRoot(self: Self, io: std.Io, scratch: std.mem.Allocator, files: *Files, row: usize, documents: *std.ArrayList(collection.Document)) !void {
    const root = self.roots[row];

    try collection.load(io, scratch, files, root.path, root.entries, documents);
}

pub fn save(self: Self, io: std.Io, files: *const Files, fingerprint: [32]u8) !void {
    if (self.facts.len == 0) return;

    var scratch = std.heap.ArenaAllocator.init(files.gpa);

    defer scratch.deinit();

    const allocator = scratch.allocator();

    const bytes = if (comptime source.binary_records)
        try encode(allocator, self.context, self.facts, files, &fingerprint) orelse return
    else
        try seed.encode(allocator, self.context, self.facts, files, &fingerprint) orelse return;

    const checksum = source.seal(bytes) orelse return;
    var file = try std.Io.Dir.cwd().createFileAtomic(io, self.path, .{ .make_path = true, .replace = true });

    defer file.deinit(io);

    try file.file.writeStreamingAll(io, &checksum);
    try file.file.writeStreamingAll(io, bytes);
    try file.replace(io);
}

fn encode(allocator: std.mem.Allocator, context: []const u8, facts: []const Fact, files: *const Files, fingerprint: *const [32]u8) !?[]const u8 {
    const records = source.records;
    const size = records.measure(facts) orelse return null;
    const rule = @import("generated_input_records_write");
    const memory = @import("zx").memory;
    const paths = memory.borrowTextColumn("path", facts);
    const Row = std.meta.Child(@FieldType(std.meta.Child(rule.Input), "versions"));
    const rows = try allocator.alloc(Row, facts.len);
    const versions = try allocator.alloc(std.meta.Child(Row), facts.len);
    const count = collectVersions(facts, files, rows, versions);

    const payload = (try rule.executeIn(allocator, &.{
        .context = context,
        .digest = fingerprint,
        .count = facts.len,
        .paths = @ptrCast(&paths),
        .versions = rows[0..count],
    })) orelse return null;

    std.debug.assert(payload.len == size);

    return payload;
}

fn collectVersions(facts: []const Fact, files: *const Files, rows: anytype, versions: anytype) usize {
    for (facts, rows, versions, 0..) |fact, *row, *out, index| {
        const version = files.version(fact.key) orelse return index;
        const modified = source.timestamp(version.metadata.mtime);
        const changed = source.timestamp(version.metadata.ctime);
        const read = source.timestamp(version.read);

        out.* = .{
            .inode = version.metadata.inode,
            .size = version.metadata.size,
            .mtime_low = modified.low,
            .ctime_low = changed.low,
            .read_low = read.low,
            .mtime_high = modified.high,
            .ctime_high = changed.high,
            .read_high = read.high,
        };

        row.* = out;
    }

    return facts.len;
}

fn observeInterfaces(io: std.Io, allocator: std.mem.Allocator, facts: *std.ArrayList(Fact), declarations: []const manifest.Interface) !bool {
    const existing = facts.items.len;

    if (comptime !source.binary_records) {
        for (declarations) |interface| {
            const matching = seed_interfaces.find("key", interface.path, facts.items[0..existing]);

            if (!try appendInterface(io, allocator, facts, interface.path, matching)) return false;
        }

        return true;
    }

    if (declarations.len == 0) return true;

    const rule = @import("generated_observe_input_interfaces");
    const memory = @import("zx").memory;
    const paths = memory.borrowTextColumn("path", declarations);
    const keys = memory.borrowTextColumn("key", facts.items);
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const observations = try rule.executeIn(arena.allocator(), &.{
        .paths = @ptrCast(&paths),
        .count = declarations.len,
        .keys = @ptrCast(&keys),
        .existing = existing,
    });

    for (observations) |observation| {
        const matching: ?usize = if (observation.matching) |row| @intCast(row) else null;

        if (!try appendInterface(io, allocator, facts, observation.path, matching)) return false;
    }

    return true;
}

fn appendInterface(io: std.Io, allocator: std.mem.Allocator, facts: *std.ArrayList(Fact), path: []const u8, matching: ?usize) !bool {
    const fact = if (matching) |row|
        facts.items[row]

    else observed: {
        const key = try std.fs.path.resolve(allocator, &.{path});
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;

        break :observed Fact.init(key, key, Files.metadata(stat));
    };

    try facts.append(allocator, fact);

    return true;
}
