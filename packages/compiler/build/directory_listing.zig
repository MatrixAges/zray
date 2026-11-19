//! Lists a directory with the metadata of each entry where the system returns both in one call, as macOS does through
//! `getattrlistbulk`: there a `stat` per file costs more than the listing itself, and calls from several threads at
//! once queue on a kernel lock. Elsewhere it lists names alone and leaves the metadata to a later `stat`.
const std = @import("std");
const builtin = @import("builtin");
const Files = @import("resident/files.zig");
const darwin = @import("compiler").source_inputs.darwin_directory;
const settings = darwin.settings;
pub const Entry = struct { name: []const u8, kind: std.Io.File.Kind, metadata: ?Files.Metadata };
pub const bulk_metadata = builtin.os.tag.isDarwin();
pub const Reader = if (bulk_metadata) Bulk else Plain;

const Plain = struct {
    iterator: std.Io.Dir.Iterator,
    pub fn init(directory: std.Io.Dir) Plain {
        return .{ .iterator = directory.iterateAssumeFirstIteration() };
    }
    pub fn next(self: *Plain, io: std.Io) !?Entry {
        const entry = try self.iterator.next(io) orelse return null;

        return .{ .name = entry.name, .kind = entry.kind, .metadata = null };
    }
};

const Bulk = struct {
    directory: std.Io.Dir,
    buffer: [settings.buffer_size]u8 align(8) = undefined,
    records: [settings.batch_size]darwin.Record = undefined,
    offset: usize = 0,
    left: usize = 0,
    ready: usize = 0,
    issued: usize = 0,
    ended: bool = false,
    const AttributeList = extern struct {
        bitmapcount: u16 = settings.bitmap_count,
        reserved: u16 = 0,
        commonattr: u32,
        volattr: u32 = 0,
        dirattr: u32 = 0,
        fileattr: u32,
        forkattr: u32 = 0,
    };

    const requested = AttributeList{ .commonattr = settings.common_request, .fileattr = settings.data_length };

    extern "c" fn getattrlistbulk(fd: std.posix.fd_t, list: *const AttributeList, buffer: [*]u8, size: usize, options: u64) c_int;

    pub fn init(directory: std.Io.Dir) Bulk {
        return .{ .directory = directory };
    }
    pub fn next(self: *Bulk, _: std.Io) !?Entry {
        if (self.issued == self.ready) {
            if (self.left == 0 and !try self.read()) return null;

            const count = @min(self.left, self.records.len);

            self.offset = try darwin.decode(&self.buffer, self.offset, self.records[0..count], builtin.cpu.arch.endian());
            self.left -= count;
            self.ready = count;
            self.issued = 0;
        }

        const record = &self.records[self.issued];

        self.issued += 1;

        return .{
            .name = record.name,
            .kind = switch (record.kind) {
                settings.regular_kind => .file,
                settings.directory_kind => .directory,
                settings.link_kind => .sym_link,
                else => .unknown,
            },
            .metadata = if (record.has_metadata) .{
                .inode = record.inode,
                .size = std.math.cast(u64, @as(i64, @bitCast(record.size))) orelse return error.InvalidDirectoryRecord,
                .mtime = time(record.modified_seconds, record.modified_nanos),
                .ctime = time(record.changed_seconds, record.changed_nanos),
            } else null,
        };
    }
    fn read(self: *Bulk) !bool {
        if (self.ended) return false;

        while (true) {
            const count = getattrlistbulk(self.directory.handle, &requested, &self.buffer, self.buffer.len, 0);

            if (count < 0) switch (std.posix.errno(count)) {
                .INTR => continue,
                else => |err| return std.posix.unexpectedErrno(err),
            };

            self.ended = count == 0;
            self.offset = 0;
            self.left = @intCast(count);

            return !self.ended;
        }
    }
    fn time(seconds: u64, nanos: u64) i96 {
        return @as(i96, @as(i64, @bitCast(seconds))) * std.time.ns_per_s + @as(i64, @bitCast(nanos));
    }
};
