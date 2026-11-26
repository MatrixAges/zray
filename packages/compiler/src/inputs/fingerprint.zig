const std = @import("std");
const zx = @import("zx");
const generated = @import("parser_options").generated_parser;
const memory = if (generated) @import("zx").memory else void;
pub const Digest = [zx.Sha256.digest_length]u8;

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
    fn out(self: *Hash) *anyopaque {
        return &self.state.writer;
    }
};

pub const Frame = struct { content: Digest, shape: Digest };

pub fn seedFrame(generator: *const Digest, manifest: []const u8, modules: anytype, interfaces: anytype) Frame {
    var content_buffer: [1024]u8 = undefined;
    var shape_buffer: [1024]u8 = undefined;
    var content = Hash.init(&content_buffer);
    var shape = Hash.init(&shape_buffer);

    frameSeed(&content, generator, manifest, true, modules, interfaces);
    frameSeed(&shape, generator, manifest, false, modules, interfaces);

    return .{ .content = content.finish(), .shape = shape.finish() };
}

fn frameSeed(hash: *Hash, generator: *const Digest, manifest: []const u8, texts: bool, modules: anytype, interfaces: anytype) void {
    hash.state.hasher.update(generator);
    field(&hash.state.hasher, if (texts) "frame" else "shape");
    field(&hash.state.hasher, manifest);

    for (modules) |*module| {
        field(&hash.state.hasher, module.path);
        if (texts) hash.state.hasher.update(&module.digest);
    }

    for (interfaces) |interface| field(&hash.state.hasher, interface.source);
}

pub fn packages(records: anytype) Digest {
    var buffer: [1024]u8 = undefined;
    var hash = Hash.init(&buffer);

    if (comptime generated) {
        const rule = @import("generated_input_text_fingerprint");
        const source = memory.borrowReadFields(.{ .first = "specifier", .second = "entry" }, records);
        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const Input = if (@typeInfo(rule.Input) == .pointer) std.meta.Child(rule.Input) else rule.Input;

        const input: Input = .{
            .out = @ptrCast(hash.out()),
            .rows = &source.bind(std.meta.Child(@FieldType(Input, "rows"))),
        };

        zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;
    } else {
        for (records) |record| {
            field(&hash.state.hasher, record.specifier);
            field(&hash.state.hasher, record.entry);
        }
    }

    return hash.finish();
}

pub fn seedOutput(digest: *const Digest, partitions: u32, sources: anytype, templates: anytype, cache: anytype) Digest {
    var buffer: [1024]u8 = undefined;
    var hash = Hash.init(&buffer);
    const out = &hash.state.hasher;

    field(out, "zxc.bootstrap.inputs.v2");
    out.update(digest);
    integer(u32, out, partitions);

    inline for (.{ sources, templates }) |rows| {
        for (rows) |row| {
            field(out, row.path);
            out.update(&cache.digest(row.path, row.source));
        }
    }

    return hash.finish();
}

pub fn snapshot(generator: *const Digest, partitions: u32, directory: []const u8, manifest: []const u8) Digest {
    if (comptime generated) {
        const rule = @import("generated_input_snapshot_fingerprint");
        var buffer: [512]u8 = undefined;
        var scratch = std.heap.FixedBufferAllocator.init(&buffer);

        const digest = rule.executeIn(scratch.allocator(), &.{
            .generator = generator,
            .partitions = partitions,
            .directory = directory,
            .manifest = manifest,
        }) catch unreachable;

        std.debug.assert(digest.len == @sizeOf(Digest));

        return digest[0..@sizeOf(Digest)].*;
    }

    var buffer: [1024]u8 = undefined;
    var hash = Hash.init(&buffer);

    hash.state.hasher.update(generator);
    integer(u32, &hash.state.hasher, partitions);
    field(&hash.state.hasher, directory);
    hash.state.hasher.update(manifest);

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
