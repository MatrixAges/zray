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

const Dispatch = struct {
    const rule = if (generated) @import("generated_function_sources_job") else void;
    const Input = if (generated) std.meta.Child(rule.Input) else void;

    jobs: Jobs,
    ids: if (generated) zx.memory.ReadColumn else void,
    regular: if (generated) zx.memory.ReadColumn else void,
    fn init(jobs: Jobs) Dispatch {
        return .{
            .jobs = jobs,
            .ids = if (generated) zx.memory.borrowReadColumn(zx.ir.FunctionId, "id", jobs.functions) else {},
            .regular = if (generated) zx.memory.borrowReadColumn(bool, "regular", jobs.functions) else {},
        };
    }
    fn at(self: *const Dispatch, position: usize) Job {
        const jobs = &self.jobs;

        if (comptime !generated) return jobs.seedAt(position);

        const functions: std.meta.Child(@FieldType(Input, "functions")) = .{
            .ids = @ptrCast(&self.ids),
            .regular = @ptrCast(&self.regular),
            .count = jobs.functions.len,
        };

        const input: Input = .{ .entries = jobs.entries.len, .types = jobs.types, .functions = &functions, .selected = jobs.positions, .position = position };
        var fixed = std.heap.FixedBufferAllocator.init(&.{});
        const route = zx.columns.invoke(rule.executeValue, fixed.allocator(), &input) catch unreachable;

        return switch (route.kind) {
            .Entry => .{ .batch = &jobs.entries[@intCast(route.index)], .unit = .entry },
            .Types => .{ .batch = jobs.batch, .unit = .types },
            .Function => .{ .batch = jobs.batch, .unit = .{ .function = @fromBackingInt(@intCast(route.index)) } },
            .Regular => .{ .batch = jobs.batch, .unit = .{ .regular = @fromBackingInt(@intCast(route.index)) } },
        };
    }
};

/// Identifies every unit and fetches its cached source.
const Search = struct {
    dispatch: *const Dispatch,
    lookups: []Batch.Lookup,
    fetched: []Cache.Fetched,
    next: std.atomic.Value(usize) = .init(0),
    failure: std.atomic.Value(u16) = .init(0),
    fn run(self: *Search, arena: *std.heap.ArenaAllocator) void {
        while (self.failure.load(.monotonic) == 0) {
            const position = self.next.fetchAdd(1, .monotonic);

            if (position >= self.lookups.len) return;

            self.step(arena.allocator(), position) catch |err| {
                _ = self.failure.cmpxchgStrong(0, @intFromError(err), .monotonic, .monotonic);

                return;
            };
        }
    }
    fn step(self: *Search, allocator: std.mem.Allocator, position: usize) generating.Error!void {
        const job = self.dispatch.at(position);
        const cache = job.batch.cache orelse return;
        const found = try job.batch.identify(allocator, job.unit);
        self.lookups[position] = found;
        self.fetched[position] = try cache.fetch(found.name, found.key, .shared);
    }
};

/// Generates every unit no cached source covers.
const Work = struct {
    dispatch: *const Dispatch,
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
            const job = self.dispatch.at(if (self.pending) |positions| @intCast(positions[position]) else position);

            self.results[position].source = generate(job, arena.allocator(), scratch.allocator(), &types) catch |err| {
                _ = self.failure.cmpxchgStrong(0, @intFromError(err), .monotonic, .monotonic);

                return;
            };
        }
    }

    fn generate(job: Job, output: std.mem.Allocator, scratch: std.mem.Allocator, types: *generating.TypeScratch) generating.Error![]const u8 {
        const backing = if (generated and job.unit == .types) job.batch.backing else scratch;

        if (generated and job.batch.cache != null) {
            const source = try job.batch.generate(scratch, backing, job.unit, types);

            return std.heap.smp_allocator.dupe(u8, source);
        }

        return job.batch.generate(output, backing, job.unit, types);
    }
};

/// Sources of `jobs` in order: cached units are copied into one buffer, the rest are generated; the search, the copies
/// and the generation run on all cores.
pub fn createJobs(owned: std.mem.Allocator, jobs: Jobs) generating.Error![][]const u8 {
    var scratch = std.heap.ArenaAllocator.init(jobs.batch.backing);

    defer scratch.deinit();

    const temporary = scratch.allocator();
    const count = jobs.count();
    const dispatch = Dispatch.init(jobs);
    const sources = try owned.alloc([]const u8, count);
    const arenas = try temporary.alloc(std.heap.ArenaAllocator, zx.parallel.width());

    for (arenas) |*arena| arena.* = .init(std.heap.smp_allocator);

    defer for (arenas) |*arena| arena.deinit();

    if (comptime generated) {
        var frame: Frame = .{
            .owned = owned,
            .temporary = temporary,
            .dispatch = &dispatch,
            .arenas = arenas,
            .sources = sources,
        };

        errdefer frame.release();

        const entry = @import("generated_run_function_sources");

        const input: std.meta.Child(entry.Input) = .{
            .batch = @ptrCast(&frame),
            .count = count,
            .cached = jobs.batch.cache != null,
        };

        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const success = entry.executeIn(empty.allocator(), &input) catch |err| return generationError(err);

        if (!success) return error.OutOfMemory;

        return sources;
    }

    const cache = jobs.batch.cache orelse {
        try produceSeed(owned, temporary, &dispatch, null, null, arenas, sources);

        return sources;
    };

    var search = Search{ .dispatch = &dispatch, .lookups = try temporary.alloc(Batch.Lookup, count), .fetched = try temporary.alloc(Cache.Fetched, count) };

    @memset(search.fetched, .{});
    errdefer for (search.fetched) |fetched| cache.releaseFetched(fetched);

    try spread(Search, &search, arenas[0..@min(arenas.len, count)]);

    const plan = try planning.create(temporary, search.fetched, cache);

    try @import("function_sources_seed.zig").restore(owned, search.fetched, plan, sources, arenas);
    for (search.lookups, search.fetched) |found, *fetched| _ = try cache.record(found.name, found.key, fetched);
    try produceSeed(owned, temporary, &dispatch, plan.pending, search.lookups, arenas, sources);

    return sources;
}

fn produceSeed(owned: std.mem.Allocator, temporary: std.mem.Allocator, dispatch: *const Dispatch, pending: ?[]const u64, lookups: ?[]const Batch.Lookup, arenas: []std.heap.ArenaAllocator, sources: [][]const u8) generating.Error!void {
    const count = if (pending) |positions| positions.len else sources.len;
    const results = try temporary.alloc(publication.Result, count);
    var work = Work{ .dispatch = dispatch, .pending = pending, .results = results };

    try spread(Work, &work, arenas[0..@min(arenas.len, count)]);

    for (results, 0..) |result, index| {
        const position = if (pending) |positions| positions[index] else index;

        sources[position] = try owned.dupe(u8, result.source.?);
    }

    if (pending) |positions| {
        for (positions) |position| try dispatch.jobs.batch.remember(lookups.?[position], sources[position]);
    }
}

const SourceReuse = if (generated) @import("output_execution_abi").layouts.@"zig:output_host".SourceReuse else void;

const CacheWork = struct {
    rows: cache_updates.CachedRows,
    plan: planning.Plan = undefined,
    view: SourceReuse = undefined,
};

const Frame = struct {
    owned: std.mem.Allocator,
    temporary: std.mem.Allocator,
    dispatch: *const Dispatch,
    arenas: []std.heap.ArenaAllocator,
    sources: [][]const u8,
    cached: ?CacheWork = null,
    results: []publication.Result = &.{},
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
    fn release(self: *const Frame) void {
        if (self.cached) |*cached| {
            for (cached.rows.fetched) |fetched| cached.rows.cache.releaseFetched(fetched);

            for (self.results) |result| {
                if (result.source) |source| std.heap.smp_allocator.free(source);
            }
        }
    }
};

pub fn readFunctionSources(handle: *const anyopaque) generating.Error!*const SourceReuse {
    const frame = Frame.borrow(handle);
    const count = frame.sources.len;
    const cache = frame.dispatch.jobs.batch.cache.?;

    var search: Search = .{
        .dispatch = frame.dispatch,
        .lookups = try frame.temporary.alloc(Batch.Lookup, count),
        .fetched = try frame.temporary.alloc(Cache.Fetched, count),
    };

    @memset(search.fetched, .{});

    frame.cached = .{ .rows = .{ .cache = cache, .lookups = search.lookups, .fetched = search.fetched } };

    try spread(Search, &search, frame.arenas[0..@min(frame.arenas.len, count)]);

    const cached = &frame.cached.?;
    const plan = try planning.create(frame.temporary, search.fetched, cache);
    cached.plan = plan;

    cached.view = .{
        .target = @ptrCast(&cached.rows),
        .count = count,
        .stored = plan.stored,
        .ordered = plan.ordered,
        .held = plan.held,
        .discarded = plan.discarded,
        .failures = plan.failures,
        .last_failure = plan.last_failure,
        .hits = plan.reused.len,
        .pending = plan.pending.len,
    };

    return &cached.view;
}

pub fn restoreFunctionSources(handle: *const anyopaque) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);
    const cached = &frame.cached.?;

    return publication.restore(frame.owned, cached.rows.fetched, cached.plan, frame.sources);
}

pub fn generateFunctionSources(handle: *const anyopaque) generating.Error!void {
    const frame = Frame.borrow(handle);
    const pending = if (frame.cached) |*cached| cached.plan.pending else null;
    const count = if (pending) |positions| positions.len else frame.sources.len;
    const results = try frame.temporary.alloc(publication.Result, count);

    if (pending != null) @memset(results, .{ .source = null });

    frame.results = results;

    var work: Work = .{ .dispatch = frame.dispatch, .pending = pending, .results = results };

    return spread(Work, &work, frame.arenas[0..@min(frame.arenas.len, count)]);
}

pub fn publishFunctionSources(handle: *const anyopaque) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);
    const pending = if (frame.cached) |*cached| cached.plan.pending else null;

    try publication.generated(frame.owned, frame.temporary, frame.results, pending, frame.sources);

    if (frame.cached) |*cached| {
        try cache_updates.commit(cached.rows.cache, cached.rows.lookups, frame.results, cached.plan.pending);
    }
}

fn generationError(err: anyerror) generating.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
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

    if (task.failure.load(.monotonic) != 0) return @errorCast(@errorFromInt(task.failure.load(.monotonic)));
}
