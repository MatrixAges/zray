const std = @import("std");
const generation = @import("compiler").zig.partition;
const Scanning = @import("scanning.zig");
const parallel = @import("../parallel.zig");
pub const File = generation.placement.File;

/// Groups public entry closures into compilation units. Source builds retain ordinary calls throughout
/// each closure; only the top-level module crosses the static ABI. The initial seed keeps its hashed layout.
/// The output allocator and workspace must be threadsafe.
pub fn plan(io: std.Io, allocator: std.mem.Allocator, workspace: std.mem.Allocator, functions: []const File, columns: generation.layout.FunctionFiles, top: []const File, count: u32) ![]File {
    if (comptime !generation.groups.available or !generation.layout.available) return @import("layout_seed.zig").plan(io, allocator, workspace, functions, top, count);

    var scratch = std.heap.ArenaAllocator.init(workspace);

    defer scratch.deinit();

    const temporary = scratch.allocator();
    const scanner = try generation.Scanning.init(temporary, columns.paths);
    const arenas = try parallel.Arenas.init(io, temporary, functions.len);

    defer arenas.deinit();

    const scanning = try Scanning.run(temporary, arenas, functions, &scanner);
    const top_callees = try temporary.alloc([]const u32, top.len);
    const top_variants = try temporary.alloc([]const []const u8, top.len);

    try scanner.scan(temporary, top, .{ .callees = top_callees, .variants = top_variants });

    var planned = try generation.layout.create(workspace, .{
        .paths = columns.paths,
        .sizes = columns.sizes,
        .callees = scanning.callees,
        .variants = scanning.variants,
        .inline_names = scanning.inline_names,
        .top_callees = top_callees,
        .top_variants = top_variants,
        .count = count,
    });

    defer planned.deinit();

    const publication = try generation.placement.publish(allocator, temporary, functions, columns.paths, &planned.value);

    const jobs = Rendering{
        .owner = allocator,
        .workspace = workspace,
        .columns = columns,
        .roots = planned.value.roots,
        .jobs = publication.jobs,
        .files = publication.files,
    };

    try parallel.each(arenas, publication.jobs.len, &jobs);

    return publication.files;
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
        const row: usize = @intCast(job.destination);

        if (!job.root) {
            self.files[row].source = try generation.namedStub(self.owner, self.workspace, self.columns.names[job.index], job.variants, job.comptime_entry);

            return;
        }

        const selected = self.roots[job.index];

        self.files[row].source = try generation.indexedExports(self.owner, self.workspace, self.columns.names, selected.entries, selected.variants);
        self.files[row + 1].source = try generation.indexedRoot(self.owner, self.workspace, self.columns, selected.callees);
    }
};
