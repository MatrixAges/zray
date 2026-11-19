const std = @import("std");
const zx = @import("zx");
const generated = @import("generated_input_snapshot");
pub const Input = std.meta.Child(generated.Input);
pub const Files = std.meta.Child(@FieldType(Input, "current"));
pub const Snapshot = std.meta.Child(@FieldType(Input, "previous"));
const source = @import("parser_options").generated_parser;
const envelope_seed = @import("snapshot/envelope_seed.zig");
pub const observed_reuse = source;
pub const storage_limit: usize = if (source) @import("generated_input_snapshot_constants").@"zx.constants".snapshot_limit else envelope_seed.limit;
const Hash = std.crypto.hash.Blake3;
const Tag = [Hash.digest_length * 2]u8;
pub const Time = struct { high: i32, low: u64 };
pub const Metadata = struct { inode: std.Io.File.INode, size: u64, mtime: i96, ctime: i96 };

pub const Observation = struct {
    path: []const u8,
    key: []const u8,
    inode: u64,
    size: u64,
    mtime_high: i32,
    mtime_low: u64,
    ctime_high: i32,
    ctime_low: u64,
    pub fn init(path: []const u8, key: []const u8, metadata: Metadata) Observation {
        const modified = timestamp(metadata.mtime);
        const changed = timestamp(metadata.ctime);

        return .{
            .path = path,
            .key = key,
            .inode = metadata.inode,
            .size = metadata.size,
            .mtime_high = modified.high,
            .mtime_low = modified.low,
            .ctime_high = changed.high,
            .ctime_low = changed.low,
        };
    }
};

pub const ObservationQuery = struct {
    context: []const u8,
    previous: *const Snapshot,
    now: Time,
};

pub fn open(allocator: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error!?[]const u8 {
    if (comptime !source) return envelope_seed.open(bytes, checksum);

    const split = @import("generated_input_snapshot_split");
    const accept = @import("generated_input_snapshot_accept");
    const frame = split.executeValue(allocator, bytes) catch |err| return envelopeFailure(err);

    if (!frame.valid) return null;

    const tag = checksum(frame.payload);
    const input: std.meta.Child(accept.Input) = .{ .stored = frame.checksum, .actual = &tag };
    const valid = zx.columns.invoke(accept.executeValue, allocator, &input) catch |err| return envelopeFailure(err);

    return if (valid) frame.payload else null;
}

pub fn seal(payload: []const u8) ?Tag {
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const allowed = if (comptime source) @import("generated_input_snapshot_fits").executeValue(empty.allocator(), payload.len) catch unreachable else envelope_seed.fits(payload.len);

    return if (allowed) checksum(payload) else null;
}

fn checksum(payload: []const u8) Tag {
    var digest: [Hash.digest_length]u8 = undefined;

    Hash.hash(payload, &digest, .{});

    return std.fmt.bytesToHex(digest, .lower);
}

fn envelopeFailure(err: anyerror) std.mem.Allocator.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };
}

pub fn timestamp(value: i96) Time {
    const bits: u96 = @bitCast(value);

    return .{ .high = @bitCast(@as(u32, @truncate(bits >> 64))), .low = @truncate(bits) };
}

pub fn residentReuse(stored: Metadata, observed: Metadata, read: i96) bool {
    if (comptime source) {
        const rule = @import("generated_input_resident_reuse");
        const Fields = std.meta.Child(rule.Input);
        const File = std.meta.Child(@FieldType(Fields, "stored"));
        const Span = std.meta.Child(@FieldType(File, "modified"));
        const stored_mtime = timeFields(Span, stored.mtime);
        const stored_ctime = timeFields(Span, stored.ctime);
        const found_mtime = timeFields(Span, observed.mtime);
        const found_ctime = timeFields(Span, observed.ctime);
        const last_read = timeFields(Span, read);
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        return rule.executeValue(empty.allocator(), &.{
            .stored = &.{ .inode = stored.inode, .size = stored.size, .modified = &stored_mtime, .changed = &stored_ctime },
            .observed = &.{ .inode = observed.inode, .size = observed.size, .modified = &found_mtime, .changed = &found_ctime },
            .read = &last_read,
        }) catch unreachable;
    }

    return stored.inode == observed.inode and stored.size == observed.size and stored.mtime == observed.mtime and stored.ctime == observed.ctime and observed.ctime + std.time.ns_per_s < read;
}

fn timeFields(comptime Fields: type, value: i96) Fields {
    const parts = timestamp(value);

    return .{ .high = parts.high, .low = parts.low };
}

pub fn reuse(allocator: std.mem.Allocator, input: Input) std.mem.Allocator.Error!bool {
    return zx.columns.invoke(generated.executeValue, allocator, &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
}

pub fn reuseObserved(observations: []const Observation, query: ObservationQuery) bool {
    const rule = @import("generated_input_snapshot_observed");
    const memory = @import("zx").memory;
    const paths = memory.borrowTextColumn("path", observations);
    const inodes = memory.borrowReadColumn(u64, "inode", observations);
    const sizes = memory.borrowReadColumn(u64, "size", observations);
    const modified_high = memory.borrowReadColumn(i32, "mtime_high", observations);
    const modified_low = memory.borrowReadColumn(u64, "mtime_low", observations);
    const changed_high = memory.borrowReadColumn(i32, "ctime_high", observations);
    const changed_low = memory.borrowReadColumn(u64, "ctime_low", observations);
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return rule.executeValue(empty.allocator(), &.{
        .context = query.context,
        .previous = query.previous,
        .now = &.{ .high = query.now.high, .low = query.now.low },
        .observed = &.{
            .paths = @ptrCast(&paths),
            .inodes = @ptrCast(&inodes),
            .sizes = @ptrCast(&sizes),
            .mtime_high = @ptrCast(&modified_high),
            .mtime_low = @ptrCast(&modified_low),
            .ctime_high = @ptrCast(&changed_high),
            .ctime_low = @ptrCast(&changed_low),
            .count = observations.len,
        },
    }) catch false;
}
