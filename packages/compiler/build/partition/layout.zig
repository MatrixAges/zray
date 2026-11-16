const std = @import("std");
const generation = @import("compiler").zig.partition;
const Scanning = @import("scanning.zig");
const parallel = @import("../parallel.zig");
pub const File = generation.placement.File;

/// Groups public entry closures into compilation units. Source builds retain ordinary calls throughout
/// each closure; only the top-level module crosses the static ABI. The initial seed keeps its hashed layout.
/// The output allocator and workspace must be threadsafe.
pub fn plan(io: std.Io, allocator: std.mem.Allocator, workspace: std.mem.Allocator, functions: []const File, top: []const File, count: u32) ![]File {
    if (comptime !generation.groups.available or !generation.layout.available) return @import("layout_seed.zig").plan(io, allocator, workspace, functions, top, count);

    var scratch = std.heap.ArenaAllocator.init(workspace);

    defer scratch.deinit();

    const temporary = scratch.allocator();
    const paths = try temporary.alloc([]const u8, functions.len);
    const sizes = try temporary.alloc(u64, functions.len);

    for (functions, paths, sizes) |function, *path, *size| {
        path.* = function.path;
        size.* = @intCast(function.source.len);
    }

    const scanner = try generation.Scanning.init(temporary, paths);
    const arenas = try parallel.Arenas.init(io, temporary, functions.len);

    defer arenas.deinit();

    const scanning = try Scanning.run(temporary, arenas, functions, &scanner);
    const top_callees = try temporary.alloc([]const u32, top.len);
    const top_variants = try temporary.alloc([]const []const u8, top.len);

    for (top, top_callees, top_variants) |file, *ids, *names| {
        const reference = try scanner.references(temporary, file.source);
        ids.* = reference.callees;
        names.* = reference.variants;
    }

    var planned = try generation.layout.create(workspace, .{
        .paths = paths,
        .sizes = sizes,
        .callees = scanning.callees,
        .variants = scanning.variants,
        .inline_names = scanning.inline_names,
        .top_callees = top_callees,
        .top_variants = top_variants,
        .count = count,
    });

    defer planned.deinit();

    const files = try generation.placement.publish(allocator, functions, paths, &planned.value);
    var position: usize = @intCast(planned.value.placement.first_stub);

    for (planned.value.scopes, 0..) |scope, index| {
        for (scope.stubs.callees, scope.stubs.variants) |callee, names| {
            files[position].source = try generation.stubBacked(allocator, workspace, paths[callee], names, index == count);
            position += 1;
        }
    }

    std.debug.assert(position == planned.value.placement.first_root);

    const roots = Roots{
        .owner = allocator,
        .workspace = workspace,
        .paths = paths,
        .plans = planned.value.roots,
        .files = files[position..],
    };

    try parallel.each(arenas, count, &roots);

    return files;
}

/// The root of each partition, exporting its functions called from outside it in name order.
const Roots = struct {
    owner: std.mem.Allocator,
    workspace: std.mem.Allocator,
    paths: []const []const u8,
    plans: @FieldType(generation.layout.Plan, "roots"),
    files: []File,
    pub fn step(self: *const Roots, allocator: std.mem.Allocator, index: usize) !void {
        const selected = self.plans[index];
        const modules = try allocator.alloc(generation.Module, selected.callees.len);
        const entries = try allocator.alloc(generation.Export, selected.entries.len);

        for (selected.callees, modules) |callee, *module| {
            const name = self.paths[callee];

            module.* = .{ .name = std.fs.path.stem(name), .file = name };
        }

        for (selected.entries, selected.variants, entries) |callee, variant, *entry| entry.* = .{ .file = self.paths[callee], .variant = variant };

        self.files[index * 2].source = try generation.exportsBacked(self.owner, self.workspace, entries);
        self.files[index * 2 + 1].source = try generation.rootBacked(self.owner, self.workspace, modules, false);
    }
};
