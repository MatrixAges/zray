const std = @import("std");
const zx = @import("zx");
const generated = @import("parser_options").generated_parser;
const memory = if (generated) @import("zx").memory else void;
pub const Digest = [zx.Sha256.digest_length]u8;
pub const batch_size = 64;

pub const Hash = struct {
    state: std.Io.Writer.Hashing(zx.Sha256),
    pub fn init(buffer: []u8) Hash {
        return .{ .state = .init(buffer) };
    }

    pub fn finish(self: *Hash) Digest {
        self.state.writer.flush() catch unreachable;

        var result: Digest = undefined;

        self.state.hasher.final(&result);

        return result;
    }
    fn out(self: *Hash) *const anyopaque {
        return &self.state.writer;
    }
};

pub fn frame(hash: *Hash, generator: *const Digest, manifest: []const u8, texts: bool, modules: anytype, interfaces: anytype) void {
    if (comptime generated) {
        const rule = @import("generated_input_frame_fingerprint");
        const Module = std.meta.Child(@TypeOf(modules));
        const paths = memory.borrowTextColumn("path", modules);
        const sources = memory.borrowTextColumn("source", interfaces);
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        comptime std.debug.assert(@FieldType(Module, "digest") == Digest);

        rule.executeValue(empty.allocator(), &.{
            .out = @ptrCast(hash.out()),
            .generator = generator,
            .manifest = manifest,
            .texts = texts,
            .modules = &.{
                .paths = @ptrCast(&paths),
                .count = modules.len,
                .digests = if (texts) std.mem.sliceAsBytes(modules) else &.{},
                .offset = @offsetOf(Module, "digest"),
                .stride = @sizeOf(Module),
            },
            .interfaces = &.{ .first = @ptrCast(&sources), .second = null, .count = interfaces.len },
        }) catch unreachable;

        return;
    }

    hash.state.hasher.update(generator);
    field(&hash.state.hasher, if (texts) "frame" else "shape");
    field(&hash.state.hasher, manifest);

    for (modules) |*module| {
        field(&hash.state.hasher, module.path);
        if (texts) hash.state.hasher.update(&module.digest);
    }

    for (interfaces) |interface| field(&hash.state.hasher, interface.source);
}

pub fn files(hash: *Hash, records: anytype, digests: []const Digest) void {
    std.debug.assert(records.len == digests.len);

    if (comptime generated) {
        const rule = @import("generated_input_file_fingerprint");
        const paths = memory.borrowTextColumn("path", records);
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        rule.executeValue(empty.allocator(), .{
            .out = @ptrCast(hash.out()),
            .rows = &.{
                .paths = @ptrCast(&paths),
                .count = records.len,
                .digests = std.mem.sliceAsBytes(digests),
                .offset = 0,
                .stride = @sizeOf(Digest),
            },
        }) catch unreachable;

        return;
    }

    for (records, digests) |record, *digest| {
        field(&hash.state.hasher, record.path);
        hash.state.hasher.update(digest);
    }
}

pub fn packages(records: anytype) Digest {
    var buffer: [1024]u8 = undefined;
    var hash = Hash.init(&buffer);

    if (comptime generated) {
        const rule = @import("generated_input_text_fingerprint");
        const specifiers = memory.borrowTextColumn("specifier", records);
        const entries = memory.borrowTextColumn("entry", records);
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        rule.executeValue(empty.allocator(), .{
            .out = @ptrCast(hash.out()),
            .rows = &.{ .first = @ptrCast(&specifiers), .second = @ptrCast(&entries), .count = records.len },
        }) catch unreachable;
    } else {
        for (records) |record| {
            field(&hash.state.hasher, record.specifier);
            field(&hash.state.hasher, record.entry);
        }
    }

    return hash.finish();
}

pub fn output(hash: *Hash, digest: *const Digest, partitions: u32) void {
    if (comptime generated) {
        const rule = @import("generated_input_output_fingerprint");
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        rule.executeValue(empty.allocator(), &.{ .out = @ptrCast(hash.out()), .frame = digest, .partitions = partitions }) catch unreachable;

        return;
    }

    field(&hash.state.hasher, "zxc.bootstrap.inputs.v2");
    hash.state.hasher.update(digest);
    integer(u32, &hash.state.hasher, partitions);
}

pub fn snapshot(generator: *const Digest, partitions: u32, directory: []const u8, manifest: []const u8) Digest {
    var buffer: [1024]u8 = undefined;
    var hash = Hash.init(&buffer);

    if (comptime generated) {
        const rule = @import("generated_input_snapshot_fingerprint");
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        rule.executeValue(empty.allocator(), &.{ .out = @ptrCast(hash.out()), .generator = generator, .partitions = partitions, .directory = directory, .manifest = manifest }) catch unreachable;
    } else {
        hash.state.hasher.update(generator);
        integer(u32, &hash.state.hasher, partitions);
        field(&hash.state.hasher, directory);
        hash.state.hasher.update(manifest);
    }

    return hash.finish();
}

fn field(hash: *zx.Sha256, bytes: []const u8) void {
    integer(u64, hash, bytes.len);
    hash.update(bytes);
}

fn integer(comptime T: type, hash: *zx.Sha256, value: T) void {
    var encoded: [@sizeOf(T)]u8 = undefined;

    std.mem.writeInt(T, &encoded, value, .little);
    hash.update(&encoded);
}
