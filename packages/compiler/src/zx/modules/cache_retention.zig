const std = @import("std");
const columns = @import("zx").columns;
const generated = @import("parser_options").generated_parser;

pub const Retention = struct {
    keep_on_publish: bool,
    keep_on_abort: bool,
    pub fn keep(self: Retention, published: bool) bool {
        return if (published) self.keep_on_publish else self.keep_on_abort;
    }
};

/// A zero mark means a version cannot be borrowed. Publishing pins all active versions marked by this request or earlier.
pub const Clock = struct {
    current: u64 = 1,
    published: u64 = 0,
    pub fn classify(self: Clock, mark: u64) Retention {
        if (comptime !generated) return .{ .keep_on_publish = mark != 0, .keep_on_abort = mark != 0 and mark <= self.published };

        const rule = @import("generated_cache_retention_classify");
        const input: std.meta.Child(rule.Input) = .{ .mark = mark, .published = self.published };
        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const result = columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;

        return .{ .keep_on_publish = result.keep_on_publish, .keep_on_abort = result.keep_on_abort };
    }

    pub fn publish(self: *Clock) void {
        if (comptime !generated) {
            self.published = self.current;
            self.current += 1;

            return;
        }

        const rule = @import("generated_cache_retention_publish");
        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const result = rule.executeValue(empty.allocator(), self.current) catch unreachable;

        self.* = .{ .current = result.current, .published = result.published };
    }
};
