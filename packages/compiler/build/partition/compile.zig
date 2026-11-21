const std = @import("std");
const file_manifest = @import("file_manifest");
const Driver = @import("driver.zig");
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

    var driver: Driver = .{
        .io = init.io,
        .allocator = allocator,
        .workspace = init.gpa,
        .request = request,
        .listed = listed,
        .selected = selected,
    };

    if (try driver.execute()) return error.PartitionCompileFailed;
}

pub const startPartitionHash = Driver.startPartitionHash;
pub const hashExternalInput = Driver.hashExternalInput;
pub const allocatePartitionKeys = Driver.allocatePartitionKeys;
pub const hashPartitionMembers = Driver.hashPartitionMembers;
pub const loadPartitionObjects = Driver.loadPartitionObjects;
pub const recordPartitionPresence = Driver.recordPartitionPresence;
pub const schedulePartitionObjects = Driver.schedulePartitionObjects;
pub const publishPartitionState = Driver.publishPartitionState;
pub const compilePartitionObjects = Driver.compilePartitionObjects;
pub const completePartitionObjects = Driver.completePartitionObjects;
pub const reportPartitionDiagnostic = Driver.reportPartitionDiagnostic;
