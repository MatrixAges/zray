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

roots: []const Root = &.{},
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

    var observed = try inspect(io, allocator, files, digest, project.interfaces, text, partitions, cache, facts);

    observed.roots = roots;

    return observed;
}

fn inspect(io: std.Io, allocator: std.mem.Allocator, files: *Files, digest: [32]u8, interfaces: []const manifest.Interface, text: []const u8, partitions: u32, cache: []const u8, source_facts: std.ArrayList(Fact)) !Self {
    var facts = source_facts;

    if (!try observeInterfaces(io, allocator, &facts, interfaces)) return .{ .facts = &.{}, .context = "", .path = "" };
    try compiler.source_inputs.order.sort(Fact, files.gpa, facts.items);

    const here = try std.process.currentPathAlloc(io, allocator);
    const identity = compiler.input_fingerprint.snapshot(&digest, partitions, here, text);
    const context = try allocator.dupe(u8, &std.fmt.bytesToHex(identity, .lower));
    const path = try std.fs.path.join(allocator, &.{ cache, name, context });
    const fingerprint = try reuseSaved(io, files.gpa, path, context, facts.items);

    return .{ .facts = facts.items, .context = context, .path = path, .fingerprint = fingerprint };
}

fn reuseSaved(io: std.Io, workspace: std.mem.Allocator, path: []const u8, context: []const u8, facts: []const Fact) !?[32]u8 {
    var scratch = std.heap.ArenaAllocator.init(workspace);

    defer scratch.deinit();

    const allocator = scratch.allocator();
    const recorded = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(source.storage_limit)) catch return null;
    const payload = try source.open(allocator, recorded) orelse return null;
    const now = source.timestamp(std.Io.Timestamp.now(io, .real).nanoseconds);

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
    const bytes = try seed.encode(allocator, self.context, self.facts, files, &fingerprint) orelse return;
    const checksum = source.seal(bytes) orelse return;
    var file = try std.Io.Dir.cwd().createFileAtomic(io, self.path, .{ .make_path = true, .replace = true });

    defer file.deinit(io);

    try file.file.writeStreamingAll(io, &checksum);
    try file.file.writeStreamingAll(io, bytes);
    try file.replace(io);
}

fn observeInterfaces(io: std.Io, allocator: std.mem.Allocator, facts: *std.ArrayList(Fact), declarations: []const manifest.Interface) !bool {
    const existing = facts.items.len;

    for (declarations) |interface| {
        const matching = seed_interfaces.find("key", interface.path, facts.items[0..existing]);

        if (!try appendInterface(io, allocator, facts, interface.path, matching)) return false;
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
