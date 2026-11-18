const std = @import("std");

pub fn decode(allocator: std.mem.Allocator, source: []const u8, maximum: usize, maximum_entries: usize) ![]u8 {
    var input: std.Io.Reader = .fixed(source);
    const window = try allocator.alloc(u8, std.compress.flate.max_window_len);

    defer allocator.free(window);

    var decoder = std.compress.flate.Decompress.init(&input, .gzip, window);
    const output = try decoder.reader.allocRemaining(allocator, .limited(maximum));

    errdefer allocator.free(output);

    const metadata = decoder.container_metadata.gzip;
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const status = @import("cli_source").archive_verify.executeValue(empty.allocator(), &.{
        .gzip = &.{
            .expected_crc = metadata.crc,
            .actual_crc = std.hash.Crc32.hash(output),
            .expected_size = metadata.count,
            .actual_size = @truncate(output.len),
            .consumed = input.seek,
            .compressed_size = source.len,
        },
        .tar = &.{
            .source = output,
            .maximum_entries = maximum_entries,
            .maximum_name = std.fs.max_path_bytes,
        },
    }) catch unreachable;

    switch (status) {
        .Valid => {},
        .Next => unreachable,
        inline else => |reason| return @field(anyerror, @tagName(reason)),
    }

    return output;
}
