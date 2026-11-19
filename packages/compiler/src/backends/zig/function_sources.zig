const std = @import("std");
const generating = @import("genz").zx.modules;
const Batch = @import("batch.zig");
const Cache = @import("cache.zig");
const publication = @import("function_sources/publication.zig");
const generated = @import("parser_options").generated_parser;
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

/// Identifies every unit and fetches its cached source.
const Search = struct {
    jobs: Jobs,
    lookups: []Batch.Lookup,
    fetched: []Cache.Fetched,
    next: std.atomic.Value(usize) = .init(0),
    failure: std.atomic.Value(u16) = .init(0),
    fn run(self: *Search, arena: *std.heap.ArenaAllocator) void {
        while (self.failure.load(.monotonic) == 0) {
            const position = self.next.fetchAdd(1, .monotonic);

            if (position >= self.jobs.count()) return;

            self.step(arena.allocator(), position) catch |err| {
                _ = self.failure.cmpxchgStrong(0, @intFromError(err), .monotonic, .monotonic);

                return;
            };
        }
    }
    fn step(self: *Search, allocator: std.mem.Allocator, position: usize) generating.Error!void {
        const job = self.jobs.at(position);
        const cache = job.batch.cache orelse return;
        const found = try job.batch.identify(allocator, job.unit);
        self.lookups[position] = found;
        self.fetched[position] = try cache.fetch(found.name, found.key, .shared);
    }
};

/// Generates every unit no cached source covers.
const Work = struct {
    jobs: Jobs,
    pending: ?[]const u64,
    results: []publication.Result,
    next: std.atomic.Value(usize) = .init(0),
    failure: std.atomic.Value(u16) = .init(0),
    /// Each unit's working memory comes from one scratch arena per worker, reset after the unit with its pages kept, so
    /// generating unit after unit reuses them instead of mapping and faulting fresh ones.
    fn run(self: *Work, arena: *std.heap.ArenaAllocator) void {
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        var types: generating.TypeScratch = .{ .allocator = std.heap.page_allocator };

        defer scratch.deinit();
        defer types.deinit();

        while (self.failure.load(.monotonic) == 0) {
            const position = self.next.fetchAdd(1, .monotonic);

            if (position >= self.results.len) return;

            defer _ = scratch.reset(.{ .retain_with_limit = 32 << 20 });
            const job = self.jobs.at(if (self.pending) |positions| @intCast(positions[position]) else position);

            self.results[position].source = generate(job, arena.allocator(), scratch.allocator(), &types) catch |err| {
                _ = self.failure.cmpxchgStrong(0, @intFromError(err), .monotonic, .monotonic);

                return;
            };
        }
    }

    fn generate(job: Job, output: std.mem.Allocator, scratch: std.mem.Allocator, types: *generating.TypeScratch) generating.Error![]const u8 {
        if (generated and job.batch.cache != null) {
            const source = try job.batch.generate(scratch, scratch, job.unit, types);

            return std.heap.smp_allocator.dupe(u8, source);
        }

        return job.batch.generate(output, scratch, job.unit, types);
    }
};

/// Sources of `jobs` in order: cached units are copied into one buffer, the rest are generated; the search, the copies
/// and the generation run on all cores.
pub fn createJobs(owned: std.mem.Allocator, jobs: Jobs) generating.Error![][]const u8 {
    var scratch = std.heap.ArenaAllocator.init(jobs.batch.backing);

    defer scratch.deinit();

    const temporary = scratch.allocator();
    const sources = try owned.alloc([]const u8, jobs.count());
    const arenas = try temporary.alloc(std.heap.ArenaAllocator, @import("zx").parallel.width());

    for (arenas) |*arena| arena.* = .init(std.heap.smp_allocator);

    defer for (arenas) |*arena| arena.deinit();

    const cache = jobs.batch.cache orelse {
        try produce(owned, temporary, jobs, null, null, arenas, sources);

        return sources;
    };

    var search = Search{ .jobs = jobs, .lookups = try temporary.alloc(Batch.Lookup, jobs.count()), .fetched = try temporary.alloc(Cache.Fetched, jobs.count()) };

    @memset(search.fetched, .{});
    errdefer for (search.fetched) |fetched| cache.releaseFetched(fetched);

    try spread(Search, &search, arenas[0..@min(arenas.len, jobs.count())]);

    const plan = try @import("function_sources_plan.zig").create(temporary, search.fetched);

    // Copy borrowed cache bytes before record can replace and release cache entries.
    if (comptime generated) {
        try publication.restore(owned, search.fetched, plan, sources);
    } else {
        try @import("function_sources_seed.zig").restore(owned, search.fetched, plan, sources, arenas);
    }

    for (plan.records.first..plan.records.end) |position| {
        const found = search.lookups[position];
        _ = try cache.record(found.name, found.key, &search.fetched[position]);
    }

    try produce(owned, temporary, jobs, plan.pending, search.lookups, arenas, sources);

    return sources;
}

fn produce(owned: std.mem.Allocator, temporary: std.mem.Allocator, jobs: Jobs, pending: ?[]const u64, lookups: ?[]const Batch.Lookup, arenas: []std.heap.ArenaAllocator, sources: [][]const u8) generating.Error!void {
    const count = if (pending) |positions| positions.len else jobs.count();
    const results = try temporary.alloc(publication.Result, count);
    var work = Work{ .jobs = jobs, .pending = pending, .results = results };

    if (generated and pending != null) @memset(results, .{ .source = null });

    defer if (generated) {
        if (pending != null) for (results) |result| {
            if (result.source) |source| std.heap.smp_allocator.free(source);
        };
    };

    try spread(Work, &work, arenas[0..@min(arenas.len, count)]);

    if (comptime generated) {
        try publication.generated(owned, temporary, results, pending, sources);
    } else {
        for (results, 0..) |result, index| {
            const position = if (pending) |positions| positions[index] else index;

            sources[position] = try owned.dupe(u8, result.source.?);
        }
    }

    if (pending) |positions| {
        for (positions, results) |position, *result| {
            const cache = jobs.batch.cache.?;
            const found = lookups.?[position];

            if (comptime generated) {
                cache.generated += 1;

                try cache.putShared(found.name, found.key, @constCast(result.source.?));

                result.source = null;
            } else try jobs.batch.remember(found, sources[position]);
        }
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

    @import("zx").parallel.spread(Shared, &shared, Shared.run, arenas.len);

    if (task.failure.load(.monotonic) != 0) return @errorCast(@errorFromInt(task.failure.load(.monotonic)));
}
