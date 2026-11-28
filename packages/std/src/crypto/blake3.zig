const std = @import("std");
const api = @import("zxc_abi").native.@"std:crypto/blake3";
const Allocator = std.mem.Allocator;
const Blake3 = std.crypto.hash.Blake3;
const Cv = [8]u32;
const cv_bytes = @sizeOf(Cv);
const counter_offset = cv_bytes;
const block_offset = counter_offset + @sizeOf(u64);
const block_len_offset = block_offset + Blake3.block_length;
const blocks_offset = block_len_offset + 1;
const stack_len_offset = blocks_offset + 1;
const stack_offset = stack_len_offset + 1;
const stack_capacity = @typeInfo(@FieldType(Blake3, "cv_stack")).array.len;
const Snapshot = [stack_offset + stack_capacity * cv_bytes]u8;
const chunk_bytes = 1024;
const file_buffer_size = 16 * 1024;

pub fn blake3Init(allocator: Allocator, input: []const u8) error{OutOfMemory}!api.Blake3State {
    var hash = Blake3.init(.{});

    hash.update(input);

    return snapshot(allocator, &hash);
}

pub fn blake3Update(allocator: Allocator, input: api.blake3Update.Input) !api.Blake3State {
    var hash = try restore(input.state);

    try checkLength(&hash, input.data.len);

    if (input.data.len == 0) return input.state;

    hash.update(input.data);

    return snapshot(allocator, &hash);
}

pub fn blake3UpdateFile(allocator: Allocator, io: std.Io, input: api.blake3UpdateFile.Input) !api.Blake3State {
    var hash = try restore(input.state);
    const prefix = input.prefix orelse &.{};
    const added = std.math.add(u64, input.size, prefix.len) catch return error.InputTooLong;

    try checkLength(&hash, added);

    if (std.mem.indexOfScalar(u8, input.path, 0) != null) return error.InvalidPath;

    const file = try std.Io.Dir.cwd().openFile(io, input.path, .{ .allow_directory = false });

    defer file.close(io);

    if (try file.length(io) != input.size) return error.FileChanged;

    hash.update(prefix);

    var buffer: [file_buffer_size]u8 = undefined;
    var offset: u64 = 0;

    while (offset < input.size) {
        const length: usize = @intCast(@min(buffer.len, input.size - offset));
        const block = buffer[0..length];

        if (try file.readPositionalAll(io, block, offset) != length) return error.FileChanged;

        hash.update(block);

        offset += length;
    }

    if (try file.length(io) != input.size) return error.FileChanged;
    if (added == 0) return input.state;

    return snapshot(allocator, &hash);
}

pub fn blake3FinalHex(allocator: Allocator, state: api.Blake3State) ![]const u8 {
    const hash = try restore(state);
    var digest: [Blake3.digest_length]u8 = undefined;

    hash.final(&digest);

    const hex = try allocator.create([digest.len * 2]u8);

    hex.* = std.fmt.bytesToHex(digest, .lower);

    return hex;
}

fn checkLength(hash: *const Blake3, added: u64) error{InputTooLong}!void {
    const used = @as(u128, hash.chunk.chunk_counter) * chunk_bytes +
        @as(u64, hash.chunk.blocks_compressed) * Blake3.block_length + hash.chunk.buf_len;

    if (used + added > std.math.maxInt(u64)) return error.InputTooLong;
}

fn snapshot(allocator: Allocator, hash: *const Blake3) error{OutOfMemory}!api.Blake3State {
    const state = try allocator.create(@typeInfo(api.Blake3State).pointer.child);

    errdefer allocator.destroy(state);

    const bytes = try allocator.create(Snapshot);

    @memset(bytes, 0);
    writeCv(bytes[0..cv_bytes], hash.chunk.cv);
    std.mem.writeInt(u64, bytes[counter_offset..][0..8], hash.chunk.chunk_counter, .little);
    @memcpy(bytes[block_offset..][0..hash.chunk.buf_len], hash.chunk.buf[0..hash.chunk.buf_len]);

    bytes[block_len_offset] = hash.chunk.buf_len;
    bytes[blocks_offset] = hash.chunk.blocks_compressed;
    bytes[stack_len_offset] = hash.cv_stack_len;

    for (0..hash.cv_stack_len) |index| {
        writeCv(bytes[stack_offset + index * cv_bytes ..][0..cv_bytes], hash.cv_stack[index]);
    }

    state.* = .{ .bytes = bytes };

    return state;
}

fn restore(state: api.Blake3State) error{InvalidState}!Blake3 {
    if (state.bytes.len != @sizeOf(Snapshot)) return error.InvalidState;

    const bytes = state.bytes;
    const counter = std.mem.readInt(u64, bytes[counter_offset..][0..8], .little);
    const block_len = bytes[block_len_offset];
    const blocks = bytes[blocks_offset];
    const stack_len = bytes[stack_len_offset];

    if (block_len > Blake3.block_length or blocks >= chunk_bytes / Blake3.block_length or
        stack_len > stack_capacity) return error.InvalidState;

    // The last subtree can be left as two stack nodes when there is no partial chunk.
    const stack_expected = @popCount(counter) + @intFromBool(block_len == 0 and counter != 0);

    if (stack_len != stack_expected or (block_len == 0 and (blocks != 0 or counter % 2 != 0)))
        return error.InvalidState;

    var hash = Blake3.init(.{});

    hash.chunk.cv = readCv(bytes[0..cv_bytes]);
    hash.chunk.chunk_counter = counter;
    hash.chunk.buf_len = block_len;
    hash.chunk.blocks_compressed = blocks;

    @memcpy(hash.chunk.buf[0..block_len], bytes[block_offset..][0..block_len]);

    hash.cv_stack_len = stack_len;

    for (0..stack_len) |index| {
        hash.cv_stack[index] = readCv(bytes[stack_offset + index * cv_bytes ..][0..cv_bytes]);
    }

    checkLength(&hash, 0) catch return error.InvalidState;

    return hash;
}

fn writeCv(out: *[cv_bytes]u8, cv: Cv) void {
    for (cv, 0..) |word, index| {
        std.mem.writeInt(u32, out[index * 4 ..][0..4], word, .little);
    }
}

fn readCv(bytes: *const [cv_bytes]u8) Cv {
    var cv: Cv = undefined;

    for (&cv, 0..) |*word, index| {
        word.* = std.mem.readInt(u32, bytes[index * 4 ..][0..4], .little);
    }

    return cv;
}
