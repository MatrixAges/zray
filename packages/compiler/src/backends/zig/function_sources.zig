const std = @import("std");
const generating = @import("genz").zx.modules;
const Batch = @import("batch.zig");
const Cache = @import("cache.zig");
const publication = @import("function_sources/publication.zig");
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
    fn at(self: Jobs, position: usize) Job {
        if (position < self.entries.len) return .{ .batch = &self.entries[position], .unit = .entry };

        const offset = position - self.entries.len;

        if (self.types and offset == 0) return .{ .batch = self.batch, .unit = .types };

        const row = offset - @intFromBool(self.types);
        const index = if (self.positions) |positions| positions[row] else row;

        return .{ .batch = self.batch, .unit = self.functions[index].unit() };
    }
};

fn runWorker(task: anytype, context: anytype, count: usize, pending: ?[]const u64) void {
    while (task.failure.load(.monotonic) == 0) {
        const row = task.next.fetchAdd(1, .monotonic);

        if (row >= count) return;

        const position = if (pending) |positions| positions[row] else row;

        context.step(row, task.jobs.at(position)) catch |err| {
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

    if (count == 0) return sources;

    const arenas = try temporary.alloc(std.heap.ArenaAllocator, zx.parallel.width());

    for (arenas) |*arena| arena.* = .init(std.heap.smp_allocator);

    defer for (arenas) |*arena| arena.deinit();

    if (comptime generated) {
        const cache = jobs.batch.cache orelse {
            const results = try temporary.alloc(publication.Result, count);
            var work: Work = .{ .jobs = &jobs, .pending = null, .results = results };

            try spread(Work, &work, arenas[0..@min(arenas.len, count)]);
            try publication.generated(owned, temporary, results, null, sources);

            return sources;
        };

        const lookups = try temporary.alloc(Batch.Lookup, count);
        const fetched = try temporary.alloc(Cache.Fetched, count);

        @memset(fetched, .{});
        errdefer for (fetched) |item| cache.releaseFetched(item);

        var search: Search = .{ .jobs = &jobs, .lookups = lookups, .fetched = fetched };

        try spread(Search, &search, arenas[0..@min(arenas.len, count)]);

        const plan = try planning.create(temporary, fetched, cache);

        if (plan.reused.len != 0) try publication.restore(owned, fetched, plan, sources);

        if (plan.ordered) {
            for (0..count) |row| _ = try cache.record(lookups[row].name, lookups[row].key, &fetched[row]);
        } else {
            var remaining = plan.stored.len;

            while (remaining != 0) {
                remaining -= 1;
                const row: usize = @intCast(plan.stored[remaining]);

                _ = cache.record(lookups[row].name, lookups[row].key, &fetched[row]) catch {
                    for (0..row) |prefix| _ = try cache.record(lookups[prefix].name, lookups[prefix].key, &fetched[prefix]);

                    return error.OutOfMemory;
                };
            }

            cache.reused += plan.held;
            cache.discarded += plan.discarded;
            cache.io_errors += plan.failures;

            if (plan.last_failure) |index| cache.last_io_error = fetched[index].failure.?;
        }

        if (plan.pending.len == 0) return sources;

        const results = try temporary.alloc(publication.Result, plan.pending.len);

        @memset(results, .{ .source = null });

        errdefer for (results) |result| {
            if (result.source) |source| std.heap.smp_allocator.free(source);
        };

        var work: Work = .{ .jobs = &jobs, .pending = plan.pending, .results = results };

        try spread(Work, &work, arenas[0..@min(arenas.len, plan.pending.len)]);
        try publication.generated(owned, temporary, results, plan.pending, sources);

        for (plan.pending, results) |position, *result| {
            const found = lookups[@intCast(position)];

            cache.generated += 1;

            try cache.putShared(found.name, found.key, result.owned.?);

            result.source = null;
            result.owned = null;
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
