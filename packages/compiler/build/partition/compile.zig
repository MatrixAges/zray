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

    const input: std.meta.Child(Driver.Input) = .{
        .arguments = request.arguments,
        .external = request.inputs,
        .generated = request.generated,
        .hashes = listed.hashes,
        .members = selected.members,
        .objects = request.objects,
        .offsets = selected.offsets,
        .paths = listed.paths,
        .prefix = @ptrCast(&@import("cache_key.zig").initial_hash),
        .signatures = selected.signatures,
        .types = selected.types,
        .zig = request.zig,
    };

    if (try Driver.execute(allocator, init.io, &input)) return error.PartitionCompileFailed;
}

pub const startPartitionHash = @import("cache_key.zig").startPartitionHash;
pub const hashExternalInput = @import("cache_key.zig").hashExternalInput;
pub const hashPartitionMembers = @import("cache_key.zig").hashPartitionMembers;
pub const loadPartitionState = @import("state.zig").loadPartitionState;
pub const partitionObjectPresent = @import("state.zig").partitionObjectPresent;
pub const compilePartitionObjects = @import("workers.zig").compilePartitionObjects;
