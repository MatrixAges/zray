const std = @import("std");

const AttributeList = extern struct {
    bitmap_count: u16 = 5,
    reserved: u16 = 0,
    common: u32 = 0x80000000 | common_metadata,
    volume: u32 = 0,
    directory: u32 = 0,
    file: u32 = file_data_length,
    fork: u32 = 0,
};

const name_attribute = 0x00000001;
const common_metadata = name_attribute | 0x00000008 | 0x00000400 | 0x00000800 | 0x02000000;
const file_data_length = 0x00000200;
const name_offset = 24;
const common_size = 76;
const file_size = 84;
const endian = @import("builtin").cpu.arch.endian();

extern "c" fn getattrlistbulk(fd: std.posix.fd_t, list: *const AttributeList, buffer: [*]u8, size: usize, options: u64) c_int;

pub const Entry = struct {
    name: []const u8,
    kind: std.Io.File.Kind,
    inode: u64,
    stat: ?Stat,
};

pub const Stat = struct {
    inode: u64,
    size: u64,
    mtime: i96,
    ctime: i96,
};

pub const Iterator = struct {
    directory: std.Io.Dir,
    buffer: [32 * 1024]u8 align(8) = undefined,
    offset: usize = 0,
    remaining: usize = 0,
    pub fn next(self: *Iterator) !?Entry {
        if (self.remaining == 0 and !try self.read()) return null;

        const tail = self.buffer[self.offset..];

        if (tail.len < 24) return error.BulkDirectoryUnavailable;

        const length = std.mem.readInt(u32, tail[0..4], endian);

        if (length < common_size or length > tail.len) return error.BulkDirectoryUnavailable;

        const row = tail[0..length];
        const common = std.mem.readInt(u32, row[4..8], endian);

        if (common & common_metadata != common_metadata) return error.BulkDirectoryUnavailable;

        const name_start = @as(i64, name_offset) + std.mem.readInt(i32, row[24..28], endian);
        const name_length = std.mem.readInt(u32, row[28..32], endian);

        if (name_start < common_size or name_length == 0 or name_start + name_length > row.len)
            return error.BulkDirectoryUnavailable;

        const start: usize = @intCast(name_start);
        const name = row[start..][0..name_length];

        if (name[name.len - 1] != 0) return error.BulkDirectoryUnavailable;

        const kind: std.Io.File.Kind = switch (std.mem.readInt(u32, row[32..36], endian)) {
            1 => .file,
            2 => .directory,
            3 => .block_device,
            4 => .character_device,
            5 => .sym_link,
            6 => .unix_domain_socket,
            7 => .named_pipe,
            else => .unknown,
        };

        const inode = std.mem.readInt(u64, row[68..76], endian);
        const returned_file = std.mem.readInt(u32, row[16..20], endian);

        const stat: ?Stat = if (kind == .file and returned_file & file_data_length != 0) blk: {
            if (start < file_size) return error.BulkDirectoryUnavailable;

            const size = std.mem.readInt(i64, row[76..84], endian);

            break :blk .{
                .inode = inode,
                .size = std.math.cast(u64, size) orelse return error.BulkDirectoryUnavailable,
                .mtime = timestamp(row[36..52]),
                .ctime = timestamp(row[52..68]),
            };
        } else null;

        self.offset += length;
        self.remaining -= 1;

        return .{ .name = name[0 .. name.len - 1], .kind = kind, .inode = inode, .stat = stat };
    }
    fn read(self: *Iterator) !bool {
        const attributes: AttributeList = .{};

        while (true) {
            const count = getattrlistbulk(self.directory.handle, &attributes, &self.buffer, self.buffer.len, 0);

            if (count < 0) switch (std.posix.errno(count)) {
                .INTR => continue,
                .INVAL, .NOSYS, .OPNOTSUPP, .RANGE => return error.BulkDirectoryUnavailable,
                .ACCES => return error.AccessDenied,
                .PERM => return error.PermissionDenied,
                else => |err| return std.posix.unexpectedErrno(err),
            };

            self.offset = 0;
            self.remaining = @intCast(count);

            return count != 0;
        }
    }
};

fn timestamp(value: *const [16]u8) i96 {
    const seconds = std.mem.readInt(i64, value[0..8], endian);
    const nanos = std.mem.readInt(i64, value[8..16], endian);

    return @as(i96, seconds) * std.time.ns_per_s + nanos;
}
