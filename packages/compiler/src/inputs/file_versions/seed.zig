const versions = @import("../file_versions.zig");
const bytes = @import("zx").bytes;

pub fn update(read: versions.Read) versions.Update {
    const mark = if (read.borrowable) read.clock.current else 0;
    var counters = read.counters;

    if (read.previous) |previous| {
        if (bytes.equal(previous.text, read.text)) return .{
            .reuse = true,
            .mark = if (previous.mark != 0) previous.mark else mark,
            .previous = null,
            .counters = counters,
        };

        const keep = read.clock.classify(previous.mark);

        counters.active = counters.active - previous.text.len + read.text.len;
        counters.publishable += @intFromBool(keep.keep_on_publish);
        counters.abortable += @intFromBool(keep.keep_on_abort);

        return .{ .reuse = false, .mark = mark, .previous = keep, .counters = counters };
    }

    counters.active += read.text.len;

    return .{ .reuse = false, .mark = mark, .previous = null, .counters = counters };
}

pub fn retire(pending: anytype, kept: [][]u8, published: bool) versions.Retired {
    var result: versions.Retired = .{};

    for (pending) |*previous| {
        if (!previous.retention.keep(published)) continue;

        kept[result.count] = previous.text;
        result.count += 1;
        result.bytes += previous.text.len;
        previous.text = &.{};
    }

    return result;
}
