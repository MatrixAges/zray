const std = @import("std");
const generating = @import("genz").zx.modules;
const zx = @import("zx");
const Batch = @import("batch.zig");
const function_sources = @import("function_sources.zig");
const indexing = @import("generated_regular_calls_index");
const scanning = @import("generated_regular_calls_scan");
const ranging = @import("generated_regular_calls_ranges");
const selection = @import("generated_regular_calls_select");
const BuildInput = std.meta.Child(indexing.Input);
const ScanInput = std.meta.Child(scanning.Input);
const Sources = std.meta.Child(@FieldType(ScanInput, "sources"));
const Ranges = std.meta.Child(@FieldType(ScanInput, "ranges"));
const Table = std.meta.Child(@FieldType(ScanInput, "table"));

pub fn complete(owned: std.mem.Allocator, batch: *const Batch, roots: []const []const u8, initializers: []const @import("modules.zig").File, units: []generating.FunctionUnit, sources: [][]const u8) generating.Error!void {
    if (comptime !@import("parser_options").generated_parser) return @import("regular_calls_seed.zig").complete(owned, batch, roots, initializers, units, sources);
    if (units.len == 0) return;

    var scratch = std.heap.ArenaAllocator.init(batch.backing);

    defer scratch.deinit();

    const temporary = scratch.allocator();
    const values = batch.analysis.value.value.values;
    const ids = zx.memory.borrowReadColumn(zx.ir.FunctionId, "id", units);
    const regular = zx.memory.borrowReadColumn(bool, "regular", units);
    const minimum = std.math.mul(usize, units.len, 2) catch return error.OutOfMemory;
    const capacity = std.math.ceilPowerOfTwo(usize, minimum) catch return error.OutOfMemory;
    const input: BuildInput = .{ .keys = batch.names.functions, .capacity = capacity, .units = &.{ .ids = @ptrCast(&ids), .regular = @ptrCast(&regular), .count = units.len }, .values = values };
    const built = zx.columns.invoke(indexing.executeValue, temporary, &input) catch |err| return failure(err);

    if (built.pending.len == 0) return;

    const wanted = try temporary.alloc(u8, values.len);

    @memset(wanted, 0);

    const read_table: Table = .{ .keys = batch.names.functions, .buckets = built.buckets, .capacity = capacity };
    const initial_sources = zx.memory.borrowTextColumn("source", initializers);
    var inputs: Sources = .{ .roots = roots, .initializers = @ptrCast(&initial_sources), .initializer_count = initializers.len, .functions = sources };
    var pending = built.pending;
    var first = true;
    var fixed_buffer = std.heap.FixedBufferAllocator.init(&.{});
    const fixed = fixed_buffer.allocator();

    while (true) {
        const range_request: std.meta.Child(ranging.Input) = .{ .sources = &inputs, .first = first };
        const ranges = zx.columns.invoke(ranging.executeValue, fixed, &range_request) catch |err| return failure(err);
        var scan = Scan{ .sources = &inputs, .ranges = zx.columns.view(Ranges, ranges), .table = &read_table, .wanted = wanted };

        try scan.run();

        const request: std.meta.Child(selection.Input) = .{ .pending = pending, .groups = built.groups, .wanted = wanted };
        const selected = zx.columns.invoke(selection.executeValue, temporary, &request) catch |err| return failure(err);

        if (selected.wave == .Converged) return;
        for (selected.ready) |position| units[@intCast(position)].regular = true;

        const regenerated = try function_sources.createJobs(owned, .{ .batch = batch, .functions = units, .positions = selected.ready });

        for (selected.ready, regenerated) |position, source| sources[@intCast(position)] = source;
        if (selected.wave == .Publish) return;

        pending = selected.pending;
        first = false;
        inputs.functions = regenerated;
    }
}

const Scan = struct {
    sources: *const Sources,
    ranges: Ranges,
    table: *const Table,
    wanted: []u8,
    next: std.atomic.Value(usize) = .init(0),
    error_code: std.atomic.Value(u16) = .init(0),
    fn run(self: *Scan) std.mem.Allocator.Error!void {
        const count: usize = @intCast(self.ranges.end);

        if (count == 0) return;

        zx.parallel.spread(Scan, self, Scan.work, @min(zx.parallel.width(), count));

        const code = self.error_code.load(.monotonic);

        if (code != 0) return @errorCast(@errorFromInt(code));
    }
    fn work(self: *Scan, _: usize) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);

        defer arena.deinit();

        var buffer: [1024]u8 = undefined;
        const count: usize = @intCast(self.ranges.end);

        while (self.error_code.load(.monotonic) == 0) {
            const position = self.next.fetchAdd(1, .monotonic);

            if (position >= count) return;

            defer _ = arena.reset(.retain_capacity);
            var buffered = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());
            const input: ScanInput = .{ .sources = self.sources, .ranges = &self.ranges, .position = position, .table = self.table };

            const hits = zx.columns.invoke(scanning.executeValue, buffered.allocator(), &input) catch |err| {
                const problem = failure(err);

                _ = self.error_code.cmpxchgStrong(0, @intFromError(problem), .monotonic, .monotonic);

                return;
            };

            for (hits) |hit| @atomicStore(u8, &self.wanted[@intCast(hit)], 1, .monotonic);
        }
    }
};

fn failure(err: anyerror) std.mem.Allocator.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => @panic("invalid regular call demand"),
    };
}
