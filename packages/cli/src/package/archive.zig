const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
pub const File = struct { path: []const u8, sha256: []const u8, executable: bool };

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    files: []const File,
    pub fn deinit(self: *Result) void {
        self.arena.deinit();

        self.* = undefined;
    }
};

const constants = @import("cli_source").store_constants.@"zx.constants";
pub const maximum_archive: usize = constants.maximum_archive;
pub const maximum_unpacked: usize = constants.maximum_unpacked;
pub const maximum_entries: usize = constants.maximum_entries;
pub const Verified = struct { source: []const u8 };

pub fn verify(source: []const u8, expected: [32]u8) !Verified {
    if (source.len > maximum_archive) return error.PackageArchiveTooLarge;

    var digest: [32]u8 = undefined;

    Sha256.hash(source, &digest, .{});

    if (!std.mem.eql(u8, &digest, &expected)) return error.PackageArchiveChecksumMismatch;

    return .{ .source = source };
}

pub fn extract(io: std.Io, allocator: std.mem.Allocator, source: []const u8, expected: [32]u8, directory: std.Io.Dir) !Result {
    return unpack(io, allocator, try verify(source, expected), directory);
}

pub fn unpack(io: std.Io, allocator: std.mem.Allocator, verified: Verified, directory: std.Io.Dir) !Result {
    const unpacked = try @import("archive/decode.zig").decode(allocator, verified.source, maximum_unpacked, maximum_entries);

    defer allocator.free(unpacked);

    var arena = std.heap.ArenaAllocator.init(allocator);

    errdefer arena.deinit();

    var input: std.Io.Reader = .fixed(unpacked);
    var names: [std.fs.max_path_bytes]u8 = undefined;
    var links: [std.fs.max_path_bytes]u8 = undefined;
    var iterator = std.tar.Iterator.init(&input, .{ .file_name_buffer = &names, .link_name_buffer = &links });

    var state: extraction.State = .{
        .io = io,
        .directory = directory,
        .allocator = arena.allocator(),
        .iterator = &iterator,
    };

    var store_arena = std.heap.ArenaAllocator.init(allocator);

    defer store_arena.deinit();

    const rule = @import("cli_source").unpack;
    const StoreState = std.meta.Child(@FieldType(rule.zx_pending, "store_0"));

    const StoreHost = struct {
        store_0: *StoreState,
        pub fn commit(self: *@This(), pending: anytype) error{}!void {
            if (pending.store_0) |next| self.store_0.* = next;
        }
    };

    var claimed_value: std.meta.Child(StoreState) = .{ .paths = &.{} };
    var claimed: StoreState = &claimed_value;
    var host: StoreHost = .{ .store_0 = &claimed };

    const status = rule.execute(&store_arena, @ptrCast(&state), &host) catch |err| switch (err) {
        error.ArchiveHostFailure => return state.failure.?,
        else => |failure| return failure,
    };

    switch (status) {
        .Valid => {},
        inline else => |reason| return @field(anyerror, @tagName(reason)),
    }

    return .{ .arena = arena, .files = try state.files.toOwnedSlice(state.allocator) };
}

pub const extraction = @import("archive/extract/storage.zig");
