const std = @import("std");
const zx = @import("zx");
const Cache = @import("../cache.zig");
const Plan = @import("../function_sources_plan.zig").Plan;
const layout = @import("generated_function_sources_offsets");
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

pub fn generated(owned: std.mem.Allocator, scratch: std.mem.Allocator, results: []const Result, positions: []const u64, target: [][]const u8) std.mem.Allocator.Error!void {
    if (positions.len == 0) return;

    const offsets = try scratch.alloc(u64, positions.len);
    const items = zx.memory.borrowReadColumn(?[]const u8, "source", results);

    const input: std.meta.Child(layout.Input) = .{
        .count = results.len,
        .items = @ptrCast(&items),
        .offsets = @ptrCast(&offsets),
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const size = (zx.columns.invoke(layout.executeValue, empty.allocator(), &input) catch |err| return failure(err)) orelse unreachable;

    try publish(owned, .{
        .items = @ptrCast(&items),
        .contiguous = true,
        .positions = positions,
        .offsets = offsets,
    }, std.math.cast(usize, size) orelse return error.OutOfMemory, target);
}

const Sources = struct {
    items: @FieldType(Copy, "items"),
    contiguous: bool,
    positions: []const u64,
    offsets: []const u64,
};

fn publish(owned: std.mem.Allocator, sources: Sources, size: usize, target: [][]const u8) std.mem.Allocator.Error!void {
    if (sources.positions.len == 0) return;

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

    const chunks = std.math.divCeil(usize, sources.positions.len, chunk_size) catch unreachable;

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
        const count = input.positions.len;
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
