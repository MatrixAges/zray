const std = @import("std");
const generating = @import("genz").zx.modules;
const zx = @import("zx");
const Batch = @import("batch.zig");
const function_sources = @import("function_sources.zig");
const indexing = @import("generated_regular_calls_index");
const scanning = @import("generated_regular_calls_scan");
const selection = @import("generated_regular_calls_select");
const publication = @import("generated_regular_calls_publish");
const BuildInput = std.meta.Child(indexing.Input);
const ScanInput = std.meta.Child(scanning.Input);
const Sources = std.meta.Child(@FieldType(ScanInput, "sources"));
const Table = std.meta.Child(@FieldType(BuildInput, "table"));
const Candidates = std.meta.Child(@FieldType(BuildInput, "candidates"));

pub fn complete(owned: std.mem.Allocator, batch: *const Batch, roots: []const []const u8, initializers: []const @import("modules.zig").File, units: []generating.FunctionUnit, sources: [][]const u8) generating.Error!void {
    if (comptime !@import("parser_options").generated_parser) return @import("regular_calls_seed.zig").complete(owned, batch, roots, initializers, units, sources);
    if (units.len == 0) return;

    var scratch = std.heap.ArenaAllocator.init(batch.backing);

    defer scratch.deinit();

    const temporary = scratch.allocator();
    const values = batch.analysis.value.value.values;
    const ids = zx.memory.borrowReadColumn(zx.ir.FunctionId, "id", units);
    const regular = zx.memory.borrowReadColumn(bool, "regular", units);
    const flags = zx.memory.borrowWriteColumn(bool, "regular", units);
    const minimum = std.math.mul(usize, units.len, 2) catch return error.OutOfMemory;
    const capacity = std.math.ceilPowerOfTwo(usize, minimum) catch return error.OutOfMemory;
    const buckets = try temporary.alloc(u64, capacity);
    const pending = try temporary.alloc(u64, units.len);
    const groups = try temporary.alloc(u64, units.len);

    @memset(buckets, 0);

    const table: Table = .{ .keys = batch.names.functions, .capacity = capacity, .buckets = @ptrCast(&buckets) };
    const candidates: Candidates = .{ .pending = @ptrCast(&pending), .groups = @ptrCast(&groups) };
    const input: BuildInput = .{ .table = &table, .candidates = &candidates, .units = &.{ .ids = @ptrCast(&ids), .regular = @ptrCast(&regular), .count = units.len }, .values = values };
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const fixed = empty.allocator();
    var count = zx.columns.invoke(indexing.executeValue, fixed, &input) catch |err| return failure(err);

    if (count == 0) return;

    const wanted = try temporary.alloc(u8, values.len);
    const positions = try temporary.alloc(u64, @intCast(count));

    @memset(wanted, 0);

    var rows: [1][]u8 = .{wanted};
    const cells: [][]u8 = &rows;
    const initial_sources = zx.memory.borrowTextColumn("source", initializers);
    var inputs: Sources = .{ .roots = roots, .initializers = @ptrCast(&initial_sources), .initializer_count = initializers.len, .functions = sources };

    while (true) {
        var scan = Scan{ .sources = &inputs, .table = &table, .wanted = @ptrCast(&cells) };

        try scan.run();

        const request: std.meta.Child(selection.Input) = .{ .candidates = &candidates, .wanted = @ptrCast(&cells), .count = count, .regular = @ptrCast(&flags), .positions = @ptrCast(&positions) };
        const selected = zx.columns.invoke(selection.executeValue, fixed, &request) catch |err| return failure(err);

        if (selected.ready == 0) return;

        const ready = positions[0..@intCast(selected.ready)];
        const regenerated = try function_sources.createJobs(owned, .{ .batch = batch, .functions = units, .positions = ready });
        const publish: std.meta.Child(publication.Input) = .{ .positions = ready, .sources = regenerated, .target = @ptrCast(&sources) };

        zx.columns.invoke(publication.executeValue, fixed, &publish) catch |err| return failure(err);

        count = selected.pending;

        if (count == 0) return;

        inputs.roots = &.{};
        inputs.initializer_count = 0;
        inputs.functions = regenerated;
    }
}

const Scan = struct {
    sources: *const Sources,
    table: *const Table,
    wanted: *const anyopaque,
    next: std.atomic.Value(usize) = .init(0),
    error_code: std.atomic.Value(u16) = .init(0),
    fn run(self: *Scan) std.mem.Allocator.Error!void {
        const count = self.sources.roots.len + self.sources.initializer_count + self.sources.functions.len;

        if (count == 0) return;

        zx.parallel.spread(Scan, self, Scan.work, @min(zx.parallel.width(), count));

        const code = self.error_code.load(.monotonic);

        if (code != 0) return @errorCast(@errorFromInt(code));
    }
    fn work(self: *Scan, _: usize) void {
        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const count = self.sources.roots.len + self.sources.initializer_count + self.sources.functions.len;

        while (self.error_code.load(.monotonic) == 0) {
            const position = self.next.fetchAdd(1, .monotonic);

            if (position >= count) return;

            const input: ScanInput = .{ .sources = self.sources, .position = position, .table = zx.columns.pointer(@FieldType(ScanInput, "table"), self.table), .wanted = @ptrCast(self.wanted) };

            zx.columns.invoke(scanning.executeValue, empty.allocator(), &input) catch |err| {
                const problem = failure(err);

                _ = self.error_code.cmpxchgStrong(0, @intFromError(problem), .monotonic, .monotonic);

                return;
            };
        }
    }
};

fn failure(err: anyerror) std.mem.Allocator.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => @panic("invalid regular call demand"),
    };
}
