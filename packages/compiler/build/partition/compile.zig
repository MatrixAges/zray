const std = @import("std");
const file_manifest = @import("file_manifest.zig");
const cache_key = @import("cache_key.zig");
const state = @import("state.zig");
const rules = @import("partition_rules");

/// Compiles the partitions of a generated tree into one object each, in a directory kept across builds:
///
///     partition-objects <zig> <generated> <objects> <count> [<input directory>...] -- <build-obj arguments>
///
/// A partition is recompiled only when its digest changes: the content hashes the generator's file manifest lists for
/// its directory, `types.zig` and `signatures.zig`, the build-obj arguments, the Zig executable and every
/// input file or directory. One Zig process per changed partition replaces a cache check per partition. In the arguments,
/// `%generated%`, `%objects%` and `%index%` stand for the tree, the object directory and the partition number.
pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const request = try rules.partition_request_parse.executeValue(allocator, args) orelse return error.MissingArguments;
    const count = try std.fmt.parseInt(u32, request.count, 10);
    const cwd = std.Io.Dir.cwd();
    const manifest_path = try std.fs.path.join(allocator, &.{ request.generated, file_manifest.name });
    const text = try cwd.readFileAlloc(init.io, manifest_path, allocator, .unlimited);
    const listed = try file_manifest.list(rules.output_manifest_read, allocator, text);

    const selected = try rules.partition_cache_selection.executeValue(allocator, &.{
        .paths = listed.paths,
        .hashes = listed.hashes,
        .count = count,
    });

    const zig_stat = try cwd.statFile(init.io, request.zig, .{});
    var shared: cache_key.Shared = .{};

    shared.init();
    shared.prefix(request.zig, zig_stat, request.arguments, selected.types orelse return error.MissingGeneratedFile, selected.signatures orelse return error.MissingGeneratedFile);

    for (request.inputs) |path| try shared.input(init.io, init.gpa, path);

    const keys = state.Keys{ .hex = try cache_key.partitions(allocator, shared.state(), listed, selected.members, selected.offsets) };
    const state_path = try std.fs.path.join(allocator, &.{ request.objects, "state" });

    const previous = cwd.readFileAlloc(init.io, state_path, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };

    try cwd.createDirPath(init.io, request.objects);

    const objects = try rules.partition_object_paths.executeValue(allocator, &.{ .objects = request.objects, .count = keys.hex.len });
    const present = try allocator.alloc(bool, objects.len);

    for (objects, present) |object, *exists| exists.* = if (cwd.access(init.io, object, .{})) true else |_| false;

    const scheduled = try keys.plan(allocator, previous, present, &.{
        .arguments = request.arguments,
        .generated = request.generated,
        .objects = request.objects,
    });

    const pending = scheduled.pending;

    if (pending.len == 0) return;
    // Drop old records before any worker can replace an object. An interrupted build can leave an object without a
    // record, which will be rebuilt even when the inputs return to their previous contents.
    if (scheduled.invalidate) try keys.write(init.io, allocator, state_path, present);

    const results = try allocator.alloc(?[]const u8, pending.len);

    var work = Work{
        .io = init.io,
        .owner = allocator,
        .zig = request.zig,
        .arguments = scheduled.arguments.values,
        .indexed = scheduled.arguments.indexed,
        .pending = pending,
        .results = results,
    };

    const threads = try allocator.alloc(std.Thread, @min(std.Thread.getCpuCount() catch 1, pending.len) -| 1);
    var started: usize = 0;

    for (threads) |*thread| {
        thread.* = std.Thread.spawn(.{}, Work.run, .{&work}) catch break;
        started += 1;
    }

    work.run();

    for (threads[0..started]) |thread| thread.join();

    const failed = try state.complete(pending, results, present);

    for (results) |result| {
        if (result) |stderr| {
            try std.Io.File.stderr().writeStreamingAll(init.io, stderr);
        }
    }

    try keys.write(init.io, allocator, state_path, present);

    if (failed) return error.PartitionCompileFailed;
}

/// Compiles the pending partitions; a result holds the compiler's output when it failed.
const Work = struct {
    io: std.Io,
    owner: std.mem.Allocator,
    zig: []const u8,
    arguments: []const []const u8,
    indexed: []const u32,
    pending: []const u32,
    results: []?[]const u8,
    next: std.atomic.Value(usize) = .init(0),
    fn run(self: *Work) void {
        while (true) {
            const position = self.next.fetchAdd(1, .monotonic);

            if (position >= self.pending.len) return;

            self.results[position] = self.compile(self.pending[position]) catch |err| @errorName(err);
        }
    }
    fn compile(self: *Work, index: u32) !?[]const u8 {
        var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);

        defer arena.deinit();

        const allocator = arena.allocator();
        const argv = try allocator.alloc([]const u8, self.arguments.len + 1);
        const target = argv[1..];

        argv[0] = self.zig;

        @memcpy(target, self.arguments);

        if (self.indexed.len != 0) try rules.partition_arguments_render.executeValue(allocator, &.{
            .values = self.arguments,
            .indexed = self.indexed,
            .index = index,
            .target = @ptrCast(&target),
        });

        const result = try std.process.run(allocator, self.io, .{ .argv = argv });

        if (result.term == .exited and result.term.exited == 0) return null;

        return try std.fmt.allocPrint(self.owner, "partition {d}: Zig terminated with {any}\n{s}", .{ index, result.term, result.stderr });
    }
};
