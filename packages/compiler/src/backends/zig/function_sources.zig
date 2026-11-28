const std = @import("std");
const generating = @import("genz").zx.modules;
const Batch = @import("batch.zig");
const Cache = @import("cache.zig");
const publication = @import("function_sources/publication.zig");
const cache_updates = @import("function_sources/cache_updates.zig");
const planning = @import("function_sources_plan.zig");
const generated = @import("parser_options").generated_parser;
const zx = @import("zx");
/// One unit to generate and the batch whose program and facts it comes from.
const Job = struct { batch: *const Batch, unit: generating.Unit };

/// Public entries, the shared types file, then reachable functions. Regeneration borrows
/// positions in the same function table, so workers can resolve a job without copying it.
pub const Jobs = struct {
    batch: *const Batch,
    entries: []const Batch = &.{},
    types: bool = false,
    functions: []const generating.FunctionUnit,
    positions: ?[]const u64 = null,
    fn count(self: Jobs) usize {
        const functions = if (self.positions) |positions| positions.len else self.functions.len;

        return self.entries.len + @intFromBool(self.types) + functions;
    }
    fn seedAt(self: Jobs, position: usize) Job {
        if (position < self.entries.len) return .{ .batch = &self.entries[position], .unit = .entry };

        const offset = position - self.entries.len;

        if (self.types and offset == 0) return .{ .batch = self.batch, .unit = .types };

        const row = offset - @intFromBool(self.types);
        const index = if (self.positions) |positions| positions[row] else row;

        return .{ .batch = self.batch, .unit = self.functions[index].unit() };
    }
};

fn locate(jobs: *const Jobs, route: anytype) Job {
    const index: usize = @intCast(route.index);

    return switch (route.kind) {
        .Entry => .{ .batch = &jobs.entries[index], .unit = .entry },
        .Types => .{ .batch = jobs.batch, .unit = .types },
        .Function => .{ .batch = jobs.batch, .unit = .{ .function = @fromBackingInt(@intCast(index)) } },
        .Regular => .{ .batch = jobs.batch, .unit = .{ .regular = @fromBackingInt(@intCast(index)) } },
    };
}

fn runWorker(task: anytype, context: anytype, count: usize, pending: ?[]const u64) void {
    if (comptime !generated) {
        while (task.failure.load(.monotonic) == 0) {
            const row = task.next.fetchAdd(1, .monotonic);

            if (row >= count) return;

            const position = if (pending) |positions| positions[row] else row;

            context.step(row, task.jobs.seedAt(position)) catch |err| {
                _ = task.failure.cmpxchgStrong(0, @intFromError(err), .monotonic, .monotonic);

                return;
            };
        }

        return;
    }

    const worker = @import("generated_function_source_worker");
    const Input = std.meta.Child(worker.Input);
    const View = std.meta.Child(@FieldType(Input, "jobs"));
    const jobs = task.jobs;
    const ids = zx.memory.borrowReadColumn(zx.ir.FunctionId, "id", jobs.functions);
    const regular = zx.memory.borrowReadColumn(bool, "regular", jobs.functions);

    const functions: std.meta.Child(@FieldType(View, "functions")) = .{
        .ids = @ptrCast(&ids),
        .regular = @ptrCast(&regular),
        .count = jobs.functions.len,
    };

    const view: View = .{
        .entries = jobs.entries.len,
        .types = jobs.types,
        .functions = &functions,
        .selected = jobs.positions,
    };

    var route_buffer: [128]u8 = undefined;
    var route_scratch = std.heap.FixedBufferAllocator.init(&route_buffer);

    while (task.failure.load(.monotonic) == 0) {
        const row = task.next.fetchAdd(1, .monotonic);

        if (row >= count) return;

        const input: Input = .{
            .jobs = &view,
            .position = if (pending) |positions| positions[row] else row,
        };

        route_scratch.reset();

        const route = zx.columns.invoke(worker.executeValue, route_scratch.allocator(), &input) catch unreachable;

        context.step(row, locate(jobs, route)) catch |err| {
            _ = task.failure.cmpxchgStrong(0, @intFromError(err), .monotonic, .monotonic);

            return;
        };
    }
}

/// Identifies every unit and fetches its cached source.
const Search = struct {
    jobs: *const Jobs,
    lookups: []Batch.Lookup,
    fetched: []Cache.Fetched,
    next: std.atomic.Value(usize) = .init(0),
    failure: std.atomic.Value(u32) = .init(0),
    fn run(self: *Search, arena: *std.heap.ArenaAllocator) void {
        var context = SearchWorker{ .task = self, .allocator = arena.allocator() };

        runWorker(self, &context, self.lookups.len, null);
    }
};

const SearchWorker = struct {
    task: *Search,
    allocator: std.mem.Allocator,
    fn step(self: *SearchWorker, row: usize, job: Job) generating.Error!void {
        const cache = job.batch.cache orelse return;
        const found = try job.batch.identify(self.allocator, job.unit);

        self.task.lookups[row] = found;
        self.task.fetched[row] = try cache.fetch(found.name, found.key, .shared);
    }
};

/// Generates every unit no cached source covers.
const Work = struct {
    jobs: *const Jobs,
    pending: ?[]const u64,
    results: []publication.Result,
    next: std.atomic.Value(usize) = .init(0),
    failure: std.atomic.Value(u32) = .init(0),
    fn run(self: *Work, arena: *std.heap.ArenaAllocator) void {
        var context = RenderWorker{
            .task = self,
            .output = arena.allocator(),
            .scratch = .init(std.heap.page_allocator),
            .types = .init(std.heap.page_allocator),
        };

        defer context.scratch.deinit();
        defer context.types.deinit();
        runWorker(self, &context, self.results.len, self.pending);
    }
};

const RenderWorker = struct {
    task: *Work,
    output: std.mem.Allocator,
    scratch: std.heap.ArenaAllocator,
    types: generating.TypeScratch,
    fn step(self: *RenderWorker, row: usize, job: Job) generating.Error!void {
        const scratch = self.scratch.allocator();
        const backing = if (generated and job.unit == .types) job.batch.backing else scratch;
        const cache_owned = generated and job.batch.cache != null;
        const source = try job.batch.generate(if (cache_owned) scratch else self.output, backing, job.unit, &self.types);

        self.task.results[row] = if (cache_owned) blk: {
            const copy = try std.heap.smp_allocator.dupe(u8, source);

            break :blk .{ .source = copy, .owned = copy };
        } else .{ .source = source };

        _ = self.scratch.reset(.{ .retain_with_limit = 32 << 20 });
    }
};

/// Sources of `jobs` in order: cached units are copied into one buffer, the rest are generated; the search, the copies
/// and the generation run on all cores.
pub fn createJobs(owned: std.mem.Allocator, jobs: Jobs) generating.Error![][]const u8 {
    var scratch = std.heap.ArenaAllocator.init(jobs.batch.backing);

    defer scratch.deinit();

    const temporary = scratch.allocator();
    const count = jobs.count();
    const sources = try owned.alloc([]const u8, count);
    const arenas = try temporary.alloc(std.heap.ArenaAllocator, zx.parallel.width());

    for (arenas) |*arena| arena.* = .init(std.heap.smp_allocator);

    defer for (arenas) |*arena| arena.deinit();

    if (comptime generated) {
        var frame: Frame = .{
            .owned = owned,
            .temporary = temporary,
            .jobs = &jobs,
            .arenas = arenas,
            .sources = sources,
        };

        errdefer frame.release();

        const entry = @import("generated_run_function_sources");
        const Input = std.meta.Child(entry.Input);
        const Reuse = std.meta.Child(@typeInfo(@FieldType(Input, "reuse")).optional.child);
        var reuse: Reuse = undefined;
        var input: Input = .{ .count = count, .cached = jobs.batch.cache != null, .reuse = null };
        var buffer: [1024]u8 = undefined;
        var buffered = std.heap.BufferFirstAllocator.init(&buffer, temporary);

        while (true) {
            const scheduled = entry.executeIn(buffered.allocator(), &input) catch |err| return generationError(err);
            var fetched = false;

            for (scheduled.steps) |step| switch (step) {
                .Fetch => {
                    try frame.fetch();

                    const plan = frame.cached.?.plan;
                    reuse = .{ .stored = plan.stored, .ordered = plan.ordered, .hits = plan.reused.len, .pending = plan.pending.len };
                    input.reuse = &reuse;
                    fetched = true;
                },
                .Restore => try frame.restore(),
                .Record => try frame.record(scheduled.record.?),
                .Account => frame.account(),
                .Generate => try frame.generate(),
                .Publish => try frame.publish(),
            };

            if (!fetched) break;
        }

        return sources;
    }

    const cache = jobs.batch.cache orelse {
        try produceSeed(owned, temporary, &jobs, null, null, arenas, sources);

        return sources;
    };

    var search = Search{ .jobs = &jobs, .lookups = try temporary.alloc(Batch.Lookup, count), .fetched = try temporary.alloc(Cache.Fetched, count) };

    @memset(search.fetched, .{});
    errdefer for (search.fetched) |fetched| cache.releaseFetched(fetched);

    try spread(Search, &search, arenas[0..@min(arenas.len, count)]);

    const plan = try planning.create(temporary, search.fetched, cache);

    try @import("function_sources_seed.zig").restore(owned, search.fetched, plan, sources, arenas);
    for (search.lookups, search.fetched) |found, *fetched| _ = try cache.record(found.name, found.key, fetched);
    try produceSeed(owned, temporary, &jobs, plan.pending, search.lookups, arenas, sources);

    return sources;
}

fn produceSeed(owned: std.mem.Allocator, temporary: std.mem.Allocator, jobs: *const Jobs, pending: ?[]const u64, lookups: ?[]const Batch.Lookup, arenas: []std.heap.ArenaAllocator, sources: [][]const u8) generating.Error!void {
    const count = if (pending) |positions| positions.len else sources.len;
    const results = try temporary.alloc(publication.Result, count);
    var work = Work{ .jobs = jobs, .pending = pending, .results = results };

    try spread(Work, &work, arenas[0..@min(arenas.len, count)]);

    for (results, 0..) |result, index| {
        const position = if (pending) |positions| positions[index] else index;

        sources[position] = try owned.dupe(u8, result.source.?);
    }

    if (pending) |positions| {
        for (positions) |position| try jobs.batch.remember(lookups.?[position], sources[position]);
    }
}

const CacheWork = struct {
    rows: cache_updates.CachedRows,
    plan: planning.Plan = undefined,
};

const Frame = struct {
    owned: std.mem.Allocator,
    temporary: std.mem.Allocator,
    jobs: *const Jobs,
    arenas: []std.heap.ArenaAllocator,
    sources: [][]const u8,
    cached: ?CacheWork = null,
    results: []publication.Result = &.{},
    fn release(self: *const Frame) void {
        if (self.cached) |*cached| {
            for (cached.rows.fetched) |fetched| cached.rows.cache.releaseFetched(fetched);

            for (self.results) |result| {
                if (result.source) |source| std.heap.smp_allocator.free(source);
            }
        }
    }
    fn fetch(self: *Frame) generating.Error!void {
        const count = self.sources.len;
        const cache = self.jobs.batch.cache.?;

        var search: Search = .{
            .jobs = self.jobs,
            .lookups = try self.temporary.alloc(Batch.Lookup, count),
            .fetched = try self.temporary.alloc(Cache.Fetched, count),
        };

        @memset(search.fetched, .{});

        self.cached = .{ .rows = .{ .cache = cache, .lookups = search.lookups, .fetched = search.fetched } };

        try spread(Search, &search, self.arenas[0..@min(self.arenas.len, count)]);

        self.cached.?.plan = try planning.create(self.temporary, search.fetched, cache);
    }
    fn record(self: *const Frame, plan: anytype) std.mem.Allocator.Error!void {
        const rows = &self.cached.?.rows;

        if (plan.order == .All) return cache_updates.record(rows, 0, self.sources.len);

        var reverse = std.mem.reverseIterator(plan.stored);

        while (reverse.next()) |row| {
            const index: usize = @intCast(row);

            cache_updates.record(rows, index, index + 1) catch |err| {
                cache_updates.record(rows, 0, index) catch {};

                return err;
            };
        }
    }
    fn account(self: *const Frame) void {
        const cached = &self.cached.?;
        const plan = cached.plan;
        const cache = cached.rows.cache;
        cache.reused += @intCast(plan.held);
        cache.discarded += @intCast(plan.discarded);
        cache.io_errors += @intCast(plan.failures);

        if (plan.last_failure) |index| cache.last_io_error = cached.rows.fetched[index].failure.?;
    }
    fn restore(self: *const Frame) std.mem.Allocator.Error!void {
        const cached = &self.cached.?;

        return publication.restore(self.owned, cached.rows.fetched, cached.plan, self.sources);
    }
    fn generate(self: *Frame) generating.Error!void {
        const pending = if (self.cached) |*cached| cached.plan.pending else null;
        const count = if (pending) |positions| positions.len else self.sources.len;
        const results = try self.temporary.alloc(publication.Result, count);

        if (pending != null) @memset(results, .{ .source = null });

        self.results = results;

        var work: Work = .{ .jobs = self.jobs, .pending = pending, .results = results };

        return spread(Work, &work, self.arenas[0..@min(self.arenas.len, count)]);
    }
    fn publish(self: *Frame) std.mem.Allocator.Error!void {
        const pending = if (self.cached) |*cached| cached.plan.pending else null;

        try publication.generated(self.owned, self.temporary, self.results, pending, self.sources);

        if (self.cached) |*cached| {
            try cache_updates.commit(cached.rows.cache, cached.rows.lookups, self.results, cached.plan.pending);
        }
    }
};

fn generationError(err: anyerror) generating.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        error.InvalidNames => error.InvalidNames,
        error.InvalidFunction => error.InvalidFunction,
        else => unreachable,
    };
}

/// Runs `task` on this thread and the shared workers, one arena per participant, and reports the first failure.
pub fn spread(comptime Task: type, task: *Task, arenas: []std.heap.ArenaAllocator) generating.Error!void {
    if (arenas.len == 0) return;

    const Shared = struct {
        task: *Task,
        arenas: []std.heap.ArenaAllocator,
        fn run(self: *@This(), participant: usize) void {
            self.task.run(&self.arenas[participant]);
        }
    };

    var shared = Shared{ .task = task, .arenas = arenas };

    zx.parallel.spread(Shared, &shared, Shared.run, arenas.len);

    const code = task.failure.load(.monotonic);

    if (code != 0) return @errorCast(@errorFromInt(@as(u16, @intCast(code))));
}
