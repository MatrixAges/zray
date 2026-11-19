const std = @import("std");
const compiler = @import("compiler");
const source = compiler.input_snapshot;
const seed = @import("input_snapshot_seed.zig");
const interfaces = compiler.source_inputs.interfaces;
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

    const matches = try allocator.alloc(interfaces.Location, project.interfaces.len);

    interfaces.locate(project.interfaces, facts.items, matches);

    for (project.interfaces, matches) |interface, match| {
        const fact: Fact = if (interfaces.sourceRow(match.source)) |row|
            facts.items[row]

        else found: {
            const path = try std.fs.path.resolve(allocator, &.{interface.path});
            const stat = std.Io.Dir.cwd().statFile(io, interface.path, .{}) catch return .{ .roots = roots, .facts = &.{}, .context = "", .path = "" };

            break :found Fact.init(path, path, Files.metadata(stat));
        };

        try facts.append(allocator, fact);
    }

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

pub fn load(self: Self, io: std.Io, scratch: std.mem.Allocator, allocator: std.mem.Allocator, files: *Files, documents: *std.ArrayList(collection.Document)) !void {
    for (self.roots) |root| try collection.load(io, scratch, allocator, files, root.path, root.entries, documents);
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
    const payload = try allocator.alloc(u8, size);
    var writer = std.Io.Writer.fixed(payload);

    try records.header(&writer, context, fingerprint, facts.len);

    var batch: [records.batch_size]records.Stored = undefined;
    var cursor: usize = 0;

    while (cursor < facts.len) {
        const count = @min(batch.len, facts.len - cursor);

        for (facts[cursor..][0..count], batch[0..count]) |*fact, *target| {
            const version = files.version(fact.key) orelse return null;
            target.* = records.Stored.init(fact.path, version.metadata, version.read);
        }

        try records.writeRows(&writer, batch[0..count]);

        cursor += count;
    }

    std.debug.assert(writer.buffered().len == size);

    return payload;
}
