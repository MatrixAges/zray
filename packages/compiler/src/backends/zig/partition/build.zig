const std = @import("std");
const generation = @import("../partition.zig");
const Scanning = @import("workers.zig");
const parallel = @import("../output/parallel.zig");
const Failure = @import("../output/failure.zig");
pub const File = generation.placement.File;
const available = generation.groups.available and generation.layout.available;
const native = if (available) @import("output_execution_abi").layouts.@"zig:output_host" else struct {};
const Plan = if (available) native.BootstrapPartitionPlan else void;
const Kind = if (available) native.PartitionFile else void;

/// Groups public entry closures into separately compiled units.
pub fn plan(io: std.Io, allocator: std.mem.Allocator, workspace: std.mem.Allocator, functions: []const File, columns: generation.layout.FunctionFiles, top: []const File, count: u32) ![]File {
    if (comptime !available) return @import("build_seed.zig").plan(io, allocator, workspace, functions, top, count);

    var scratch = std.heap.ArenaAllocator.init(workspace);

    defer scratch.deinit();

    const temporary = scratch.allocator();
    const scanner = try generation.Scanning.init(temporary, columns.paths);
    const arenas = try parallel.Arenas.init(io, temporary, functions.len);

    defer arenas.deinit();

    var frame: Frame = .{
        .allocator = allocator,
        .workspace = workspace,
        .temporary = temporary,
        .functions = functions,
        .columns = columns,
        .top = top,
        .count = count,
        .scanner = &scanner,
        .arenas = arenas,
    };

    defer if (frame.planned) |*planned| planned.deinit();

    const entry = @import("generated_bootstrap_partition");
    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    _ = entry.executeIn(fixed.allocator(), @ptrCast(&frame)) catch |err| return frame.failure.restore(err);

    return frame.publication.files;
}

const Frame = struct {
    allocator: std.mem.Allocator,
    workspace: std.mem.Allocator,
    temporary: std.mem.Allocator,
    functions: []const File,
    columns: generation.layout.FunctionFiles,
    top: []const File,
    count: u32,
    scanner: *const generation.Scanning,
    arenas: parallel.Arenas,
    scanning: Scanning = undefined,
    top_callees: [][]const u32 = undefined,
    top_variants: [][]const []const u8 = undefined,
    planned: ?generation.layout.Owned = null,
    publication: generation.placement.Publication = undefined,
    result: Plan = undefined,
    failure: Failure = .{},
    fn borrow(handle: *const anyopaque) *@This() {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
    fn scanBodies(self: *Frame) !void {
        self.scanning = try Scanning.run(self.temporary, self.arenas, self.functions, self.scanner);
    }

    fn scanSupport(self: *Frame) !void {
        self.top_callees = try self.temporary.alloc([]const u32, self.top.len);
        self.top_variants = try self.temporary.alloc([]const []const u8, self.top.len);

        try self.scanner.scan(self.temporary, self.top, .{ .callees = self.top_callees, .variants = self.top_variants });
    }
    fn layout(self: *Frame) !void {
        self.planned = try generation.layout.create(self.workspace, .{
            .paths = self.columns.paths,
            .sizes = self.columns.sizes,
            .callees = self.scanning.callees,
            .variants = self.scanning.variants,
            .inline_names = self.scanning.inline_names,
            .top_callees = self.top_callees,
            .top_variants = self.top_variants,
            .count = self.count,
        });
    }
    fn place(self: *Frame) !void {
        self.publication = try generation.placement.publish(self.allocator, self.temporary, self.functions, self.columns.paths, &self.planned.?.value);
    }
};

pub fn scanPartitionBodies(handle: *const anyopaque) Failure.Error!void {
    const frame = Frame.borrow(handle);

    frame.scanBodies() catch |err| return frame.failure.save(err);
}

pub fn scanPartitionSupport(handle: *const anyopaque) Failure.Error!void {
    const frame = Frame.borrow(handle);

    frame.scanSupport() catch |err| return frame.failure.save(err);
}

pub fn planPartitionLayout(handle: *const anyopaque) Failure.Error!void {
    const frame = Frame.borrow(handle);

    frame.layout() catch |err| return frame.failure.save(err);
}

pub fn placePartitionFiles(handle: *const anyopaque) Failure.Error!*const Plan {
    const frame = Frame.borrow(handle);

    frame.place() catch |err| return frame.failure.save(err);

    frame.result = .{ .target = @ptrCast(frame), .jobs = frame.publication.jobs.len };

    return &frame.result;
}

pub fn emitPartitionJobs(handle: *const anyopaque) Failure.Error!void {
    const frame = Frame.borrow(handle);

    const render: Rendering = .{
        .owner = frame.allocator,
        .workspace = frame.workspace,
        .columns = frame.columns,
        .roots = frame.planned.?.value.roots,
        .jobs = frame.publication.jobs,
        .files = frame.publication.files,
    };

    parallel.each(frame.arenas, render.jobs.len, &render) catch |err| return frame.failure.save(err);
}

const Rendering = struct {
    owner: std.mem.Allocator,
    workspace: std.mem.Allocator,
    columns: generation.layout.FunctionFiles,
    roots: @FieldType(generation.layout.Plan, "roots"),
    jobs: []const generation.placement.Job,
    files: []File,
    pub fn step(self: *const Rendering, _: std.mem.Allocator, index: usize) !void {
        const job = &self.jobs[index];
        var current: Job = .{ .rendering = self, .job = job };
        const entry = @import("generated_bootstrap_partition_job");
        const input: std.meta.Child(entry.Input) = .{ .target = @ptrCast(&current), .root = job.root };
        var fixed = std.heap.FixedBufferAllocator.init(&.{});

        entry.executeValue(fixed.allocator(), &input) catch |err| return current.failure.restore(err);
    }
};

const Job = struct {
    rendering: *const Rendering,
    job: *const generation.placement.Job,
    failure: Failure = .{},
    fn render(self: *const Job, kind: Kind) !void {
        const rendering = self.rendering;
        const job = self.job;
        const row: usize = @intCast(job.destination);

        switch (kind) {
            .Stub => rendering.files[row].source = try generation.namedStub(rendering.owner, rendering.workspace, rendering.columns.names[job.index], job.variants, job.comptime_entry),
            .Exports => {
                const selected = rendering.roots[job.index];

                rendering.files[row].source = try generation.indexedExports(rendering.owner, rendering.workspace, rendering.columns.names, selected.entries, selected.variants);
            },
            .Modules => {
                const selected = rendering.roots[job.index];

                rendering.files[row + 1].source = try generation.indexedRoot(rendering.owner, rendering.workspace, rendering.columns, selected.callees);
            },
        }
    }
};

pub fn renderPartitionFile(handle: *const anyopaque, kind: Kind) Failure.Error!void {
    const frame: *Job = @ptrCast(@alignCast(@constCast(handle)));

    frame.render(kind) catch |err| return frame.failure.save(err);
}
