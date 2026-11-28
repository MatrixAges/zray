const std = @import("std");
const Snapshot = @import("../snapshot.zig");
const read = @import("read.zig");
const storage = @import("storage.zig");
const rule = @import("cli_source").scan;
const Request = std.meta.Child(rule.Input);
const Row = std.meta.Child(std.meta.Elem(@FieldType(Request, "rows")));

pub fn scan(snapshot: Snapshot, io: std.Io, allocator: std.mem.Allocator, versioned: bool, reuse_versions: bool) !bool {
    if (!snapshot.consistent) return false;

    const started = if (versioned) read.timestamp(std.Io.Timestamp.now(io, .real).nanoseconds) else null;
    var scratch = std.heap.ArenaAllocator.init(allocator);

    defer scratch.deinit();

    const temporary = scratch.allocator();
    const count = snapshot.entries.len;
    const rows = try temporary.alloc(Row, count);
    const views = try temporary.alloc(*const Row, count);
    const facts = try temporary.alloc(storage.Fact, count);
    const versions: []read.VersionFields = if (reuse_versions) try temporary.alloc(read.VersionFields, count) else &.{};

    for (snapshot.entries, rows, views, facts, 0..) |*entry, *row, *view, *fact, index| {
        fact.* = Snapshot.fact(&entry.state);

        row.* = .{
            .path = entry.path,
            .directory_entries = entry.directory_entries,
            .fact = fact,
            .verified = if (reuse_versions and entry.verified_file != null) verified: {
                const fields = &versions[index];

                fields.init(entry.verified_file.?);

                break :verified &fields.view;
            } else null,
        };

        view.* = row;
    }

    const result = try rule.executeIn(temporary, &.{
        .rows = views,
        .consistent = snapshot.consistent,
        .started = if (started) |*stamp| stamp else null,
        .reuse_versions = reuse_versions,
    }, io);

    for (result.updates) |update| {
        snapshot.entries[@intCast(update.row)].verified_file = if (update.verified) |version| read.versionFromFields(version) else null;
    }

    if (result.failure) |failure| return read.failure(failure);

    return result.same;
}
