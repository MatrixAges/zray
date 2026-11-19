const std = @import("std");
const compiler = @import("compiler");
const source = compiler.input_snapshot;
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
    const previous = std.json.parseFromSliceLeaky(source.Snapshot, allocator, payload, .{}) catch return null;
    const now = source.timestamp(std.Io.Timestamp.now(io, .real).nanoseconds);

    if (comptime source.observed_reuse) {
        if (!source.reuseObserved(facts, .{
            .context = context,
            .previous = &previous,
            .now = now,
        })) return null;
    } else {
        const observed = (try columns(allocator, facts, null)).?;

        if (!try source.reuse(allocator, .{
            .context = context,
            .current = &observed,
            .previous = &previous,
            .now_high = now.high,
            .now_low = now.low,
            .stored_checksum = "",
            .actual_checksum = "",
        })) return null;
    }

    var digest: [32]u8 = undefined;

    _ = std.fmt.hexToBytes(&digest, previous.fingerprint) catch return null;

    return digest;
}

pub fn load(self: Self, io: std.Io, scratch: std.mem.Allocator, allocator: std.mem.Allocator, files: *Files, documents: *std.ArrayList(collection.Document)) !void {
    for (self.roots) |root| try collection.load(io, scratch, allocator, files, root.path, root.entries, documents);
}

pub fn save(self: Self, io: std.Io, files: *const Files, fingerprint: [32]u8) !void {
    if (self.facts.len == 0) return;

    var scratch = std.heap.ArenaAllocator.init(files.gpa);

    defer scratch.deinit();

    const allocator = scratch.allocator();
    const contents = try columns(allocator, self.facts, files) orelse return;
    const snapshot: source.Snapshot = .{ .context = self.context, .fingerprint = &std.fmt.bytesToHex(fingerprint, .lower), .files = &contents };
    const bytes = try std.json.Stringify.valueAlloc(allocator, snapshot, .{});
    const checksum = source.seal(bytes) orelse return;
    var file = try std.Io.Dir.cwd().createFileAtomic(io, self.path, .{ .make_path = true, .replace = true });

    defer file.deinit(io);

    try file.file.writeStreamingAll(io, &checksum);
    try file.file.writeStreamingAll(io, bytes);
    try file.replace(io);
}

fn columns(allocator: std.mem.Allocator, facts: []const Fact, files: ?*const Files) !?source.Files {
    var result: source.Files = undefined;

    inline for (@typeInfo(source.Files).@"struct".field_names) |field| {
        const Child = std.meta.Child(@FieldType(source.Files, field));

        @field(result, field) = try allocator.alloc(Child, if (files == null and std.mem.startsWith(u8, field, "read_")) 0 else facts.len);
    }

    for (facts, 0..) |fact, index| {
        const version = if (files) |cache| cache.version(fact.key) orelse return null else null;
        const selected = if (version) |value| Fact.init(fact.path, fact.key, value.metadata) else fact;

        @constCast(result.paths)[index] = selected.path;
        @constCast(result.inodes)[index] = selected.inode;
        @constCast(result.sizes)[index] = selected.size;
        @constCast(result.mtime_high)[index] = selected.mtime_high;
        @constCast(result.mtime_low)[index] = selected.mtime_low;
        @constCast(result.ctime_high)[index] = selected.ctime_high;
        @constCast(result.ctime_low)[index] = selected.ctime_low;

        if (version) |value| timestamp(&result, "read", index, value.read);
    }

    return result;
}

fn timestamp(columns_value: *source.Files, comptime field: []const u8, index: usize, value: i96) void {
    const parts = source.timestamp(value);

    @constCast(@field(columns_value, field ++ "_low"))[index] = parts.low;
    @constCast(@field(columns_value, field ++ "_high"))[index] = parts.high;
}
