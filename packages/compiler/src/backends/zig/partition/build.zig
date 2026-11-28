const std = @import("std");
const generation = @import("../partition.zig");
const Scanning = @import("workers.zig");
const parallel = @import("../output/parallel.zig");
const Failure = @import("../output/failure.zig");
pub const File = generation.placement.File;
const available = generation.groups.available and generation.layout.available;

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
    const emit = entry.executeIn(fixed.allocator(), @ptrCast(&frame)) catch |err| return frame.failure.restore(err);

    if (emit) try emitJobs(&frame);

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
    failure: Failure = .{},
    fn borrow(handle: *anyopaque) *@This() {
        return @ptrCast(@alignCast(handle));
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

pub fn scanPartitionBodies(handle: *anyopaque) Failure.Error!void {
    const frame = Frame.borrow(handle);

    frame.scanBodies() catch |err| return frame.failure.save(err);
}

pub fn scanPartitionSupport(handle: *anyopaque) Failure.Error!void {
    const frame = Frame.borrow(handle);

    frame.scanSupport() catch |err| return frame.failure.save(err);
}

pub fn planPartitionLayout(handle: *anyopaque) Failure.Error!void {
    const frame = Frame.borrow(handle);

    frame.layout() catch |err| return frame.failure.save(err);
}

pub fn placePartitionFiles(handle: *anyopaque) Failure.Error!u64 {
    const frame = Frame.borrow(handle);

    frame.place() catch |err| return frame.failure.save(err);

    return frame.publication.jobs.len;
}

fn emitJobs(frame: *const Frame) !void {
    return parallel.eachRender(frame.arenas, .{
        .owner = frame.allocator,
        .workspace = frame.workspace,
        .columns = frame.columns,
        .roots = frame.planned.?.value.roots,
        .jobs = frame.publication.jobs,
        .files = frame.publication.files,
    });
}
