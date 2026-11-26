const std = @import("std");
const rules = @import("partition_rules");
const scheduling = rules.partition_cache_schedule;
const ScheduleSignature = @typeInfo(@TypeOf(scheduling.executeValue)).@"fn";
pub const Schedule = @typeInfo(ScheduleSignature.return_type.?).error_union.payload;
const Options = std.meta.Child(@FieldType(std.meta.Child(ScheduleSignature.param_types[1].?), "options"));

pub const Keys = struct {
    hex: []const []const u8,
    /// Replaces presence with the entries safe to record before spawning any worker.
    pub fn plan(self: Keys, allocator: std.mem.Allocator, previous: []const u8, present: []bool, options: *const Options) !Schedule {
        var bytes = std.mem.sliceAsBytes(present);

        return scheduling.executeValue(allocator, &.{
            .state = &.{
                .previous = previous,
                .digests = self.hex,
                .present = present,
                .target = @ptrCast(&bytes),
            },
            .options = options,
        });
    }
    pub fn write(self: Keys, io: std.Io, allocator: std.mem.Allocator, path: []const u8, valid: []const bool) !void {
        var arena = std.heap.ArenaAllocator.init(allocator);

        defer arena.deinit();

        const text = try rules.partition_cache_publish.executeIn(arena.allocator(), &.{
            .digests = self.hex,
            .valid = valid,
        });

        var file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });

        defer file.deinit(io);

        try file.file.writeStreamingAll(io, text);
        try file.replace(io);
    }
};

pub fn complete(pending: []const u32, failures: []const ?[]const u8, valid: []bool) !bool {
    var bytes = std.mem.sliceAsBytes(valid);
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return rules.partition_cache_complete.executeValue(empty.allocator(), &.{
        .pending = pending,
        .failures = failures,
        .target = @ptrCast(&bytes),
    });
}
