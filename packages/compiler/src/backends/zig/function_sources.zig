const std = @import("std");
const generating = @import("genz").zx.modules;
const Batch = @import("batch.zig");
const Cache = @import("cache.zig");
const publication = @import("function_sources/publication.zig");
const generated = @import("parser_options").generated_parser;
/// One unit to generate and the batch whose program and facts it comes from.
pub const Job = struct { batch: *const Batch, unit: generating.Unit };

/// Identifies every unit and fetches its cached source.
const Search = struct {
    jobs: []const Job,
    lookups: []Batch.Lookup,
    fetched: []Cache.Fetched,
    next: std.atomic.Value(usize) = .init(0),
    failure: std.atomic.Value(u16) = .init(0),
    fn run(self: *Search, arena: *std.heap.ArenaAllocator) void {
        while (self.failure.load(.monotonic) == 0) {
            const position = self.next.fetchAdd(1, .monotonic);

            if (position >= self.jobs.len) return;

            self.step(arena.allocator(), position) catch |err| {
                _ = self.failure.cmpxchgStrong(0, @intFromError(err), .monotonic, .monotonic);

                return;
            };
        }
    }
    fn step(self: *Search, allocator: std.mem.Allocator, position: usize) generating.Error!void {
        const job = self.jobs[position];
        const cache = job.batch.cache orelse return;
        const found = try job.batch.identify(allocator, job.unit);
        self.lookups[position] = found;
        self.fetched[position] = try cache.fetch(found.name, found.key, .shared);
    }
};

/// Generates every unit no cached source covers.
const Work = struct {
    jobs: []const Job,
    pending: ?[]const u64,
    results: []publication.Result,
    next: std.atomic.Value(usize) = .init(0),
    failure: std.atomic.Value(u16) = .init(0),
    /// Each unit's working memory comes from one scratch arena per worker, reset after the unit with its pages kept, so
    /// generating unit after unit reuses them instead of mapping and faulting fresh ones.
    fn run(self: *Work, arena: *std.heap.ArenaAllocator) void {
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);

        defer scratch.deinit();

        while (self.failure.load(.monotonic) == 0) {
            const position = self.next.fetchAdd(1, .monotonic);

            if (position >= self.results.len) return;

            defer _ = scratch.reset(.{ .retain_with_limit = 32 << 20 });
            const job = self.jobs[if (self.pending) |positions| @intCast(positions[position]) else position];

            self.results[position].source = generate(job, arena.allocator(), scratch.allocator()) catch |err| {
                _ = self.failure.cmpxchgStrong(0, @intFromError(err), .monotonic, .monotonic);

                return;
            };
        }
    }

    fn generate(job: Job, output: std.mem.Allocator, scratch: std.mem.Allocator) generating.Error![]const u8 {
        if (generated and job.batch.cache != null) {
            const source = try job.batch.generate(scratch, scratch, job.unit);

            return std.heap.smp_allocator.dupe(u8, source);
        }

        return job.batch.generate(output, scratch, job.unit);
    }
};

/// Sources of function `units` in order.
pub fn create(owned: std.mem.Allocator, batch: *const Batch, units: []const generating.Unit) generating.Error![][]const u8 {
    const jobs = try batch.backing.alloc(Job, units.len);

    defer batch.backing.free(jobs);

    for (units, jobs) |unit, *job| job.* = .{ .batch = batch, .unit = unit };

    return createJobs(owned, batch.backing, jobs);
}

/// Sources of `jobs` in order: cached units are copied into one buffer, the rest are generated; the search, the copies
/// and the generation run on all cores.
pub fn createJobs(owned: std.mem.Allocator, backing: std.mem.Allocator, jobs: []const Job) generating.Error![][]const u8 {
    var scratch = std.heap.ArenaAllocator.init(backing);

    defer scratch.deinit();

    const temporary = scratch.allocator();
    const sources = try owned.alloc([]const u8, jobs.len);
    const arenas = try temporary.alloc(std.heap.ArenaAllocator, @import("zx").parallel.width());

    for (arenas) |*arena| arena.* = .init(std.heap.smp_allocator);

    defer for (arenas) |*arena| arena.deinit();

    if (!hasCache(jobs)) {
        try produce(owned, temporary, jobs, null, null, arenas, sources);

        return sources;
    }

    var search = Search{ .jobs = jobs, .lookups = try temporary.alloc(Batch.Lookup, jobs.len), .fetched = try temporary.alloc(Cache.Fetched, jobs.len) };

    @memset(search.fetched, .{});

    errdefer for (jobs, search.fetched) |job, fetched| {
        if (job.batch.cache) |cache| cache.releaseFetched(fetched);
    };

    try spread(Search, &search, arenas[0..@min(arenas.len, jobs.len)]);

    const plan = try @import("function_sources_plan.zig").create(temporary, search.fetched);

    // Copy borrowed cache bytes before record can replace and release cache entries.
    if (comptime generated) {
        try publication.restore(owned, search.fetched, plan, sources);
    } else {
        try @import("function_sources_seed.zig").restore(owned, search.fetched, plan, sources, arenas);
    }

    for (plan.records.first..plan.records.end) |position| {
        const job = jobs[position];

        if (job.batch.cache) |cache| {
            const found = search.lookups[position];
            _ = try cache.record(found.name, found.key, &search.fetched[position]);
        }
    }

    try produce(owned, temporary, jobs, plan.pending, search.lookups, arenas, sources);

    return sources;
}

fn hasCache(jobs: []const Job) bool {
    for (jobs) |job| if (job.batch.cache != null) return true;

    return false;
}

fn produce(owned: std.mem.Allocator, temporary: std.mem.Allocator, jobs: []const Job, pending: ?[]const u64, lookups: ?[]const Batch.Lookup, arenas: []std.heap.ArenaAllocator, sources: [][]const u8) generating.Error!void {
    const count = if (pending) |positions| positions.len else jobs.len;
    const results = try temporary.alloc(publication.Result, count);
    var work = Work{ .jobs = jobs, .pending = pending, .results = results };

    if (generated and pending != null) @memset(results, .{ .source = null });

    defer if (generated) {
        if (pending) |positions| for (positions, results) |position, result| {
            if (jobs[position].batch.cache != null) {
                if (result.source) |source| std.heap.smp_allocator.free(source);
            }
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
            const job = jobs[position];
            const cache = job.batch.cache orelse continue;
            const found = lookups.?[position];

            if (comptime generated) {
                cache.generated += 1;

                try cache.putShared(found.name, found.key, @constCast(result.source.?));

                result.source = null;
            } else try job.batch.remember(found, sources[position]);
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
