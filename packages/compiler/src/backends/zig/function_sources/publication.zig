const std = @import("std");
const zx = @import("zx");
const Cache = @import("../cache.zig");
const planning = @import("../function_sources_plan.zig");
const Plan = planning.Plan;
const copying = @import("generated_function_sources_copy");
const Copy = std.meta.Child(copying.Input);
const chunk_size = 16;
pub const Result = struct { source: ?[]const u8 };

pub fn restore(owned: std.mem.Allocator, fetched: []const Cache.Fetched, plan: Plan, target: [][]const u8) std.mem.Allocator.Error!void {
    const items = zx.memory.borrowReadColumn(?[]const u8, "source", fetched);

    try publish(owned, .{
        .items = @ptrCast(&items),
        .contiguous = false,
        .positions = plan.reused,
        .offsets = plan.offsets,
    }, plan.size, target);
}

pub fn generated(owned: std.mem.Allocator, scratch: std.mem.Allocator, results: []const Result, positions: ?[]const u64, target: [][]const u8) std.mem.Allocator.Error!void {
    if (results.len == 0) return;

    const offsets = try scratch.alloc(u64, results.len);
    const items = zx.memory.borrowReadColumn(?[]const u8, "source", results);
    const size = try planning.layout(&items, offsets);

    try publish(owned, .{
        .items = @ptrCast(&items),
        .contiguous = true,
        .positions = positions,
        .offsets = offsets,
    }, size, target);
}

const Sources = struct {
    items: @FieldType(Copy, "items"),
    contiguous: bool,
    positions: ?[]const u64,
    offsets: []const u64,
};

fn publish(owned: std.mem.Allocator, sources: Sources, size: usize, target: [][]const u8) std.mem.Allocator.Error!void {
    if (sources.offsets.len == 0) return;

    const data = try owned.alloc(u8, size);

    errdefer owned.free(data);

    var workers = Workers{ .input = .{
        .items = sources.items,
        .contiguous = sources.contiguous,
        .positions = sources.positions,
        .offsets = sources.offsets,
        .data = data,
        .target = @ptrCast(&target),
        .buffer = @ptrCast(&data),
        .first = 0,
        .end = 0,
    } };

    const chunks = std.math.divCeil(usize, sources.offsets.len, chunk_size) catch unreachable;

    zx.parallel.spread(Workers, &workers, Workers.run, @min(zx.parallel.width(), chunks));

    const code = workers.error_code.load(.monotonic);

    if (code != 0) return @errorCast(@errorFromInt(code));
}

const Workers = struct {
    input: Copy,
    next: std.atomic.Value(usize) = .init(0),
    error_code: std.atomic.Value(u16) = .init(0),
    fn run(self: *Workers, _: usize) void {
        var input = self.input;
        const count = input.offsets.len;
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        while (self.error_code.load(.monotonic) == 0) {
            const first = self.next.fetchAdd(chunk_size, .monotonic);

            if (first >= count) return;

            input.first = first;
            input.end = first + @min(chunk_size, count - first);

            const request: *const Copy = &input;

            const valid = zx.columns.invoke(copying.executeValue, empty.allocator(), request) catch |err| {
                self.error_code.store(@intFromError(failure(err)), .monotonic);

                return;
            };

            if (!valid) unreachable;
        }
    }
};

fn failure(err: anyerror) std.mem.Allocator.Error {
    return switch (err) {
        error.OutOfMemory, error.Overflow => error.OutOfMemory,
        else => @panic("invalid function source publication"),
    };
}
