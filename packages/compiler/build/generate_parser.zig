const std = @import("std");
const compiler = @import("compiler");
const analysis = @import("rx_analysis");
const collection = @import("source_collection.zig");
const manifest = @import("generation_manifest.zig");
const Resident = @import("resident/state.zig");
const Files = @import("resident/files.zig");
const InputSnapshot = @import("input_snapshot.zig");
const fingerprint = compiler.input_fingerprint;
const publication = compiler.input_generation;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const kind = compiler.resident_protocol.command(args);

    return switch (kind) {
        .Missing => error.MissingCommand,
        .Unknown => error.UnknownCommand,
        .Incomplete => error.OutputCountMismatch,
        .Lexer => @import("generate_lexer.zig").generate(init, args[2], args[3], args[4]),
        .StandardAbi => @import("generate_types.zig").generate(init, args[2]),
        .Manifest, .Partitioned => @import("resident/service.zig").run(init, .{
            .manifest = args[2],
            .output = args[3],
            .cache = args[4],
            .partitions = if (kind == .Partitioned) try std.fmt.parseInt(u32, args[6], 10) else 0,
        }),
        .Serve, .Warm => @import("resident/service.zig").serve(init, args[2], if (kind == .Warm) .{
            .manifest = args[3],
            .output = args[4],
            .cache = args[2],
            .partitions = try std.fmt.parseInt(u32, args[5], 10),
            .write = false,
        } else null),
    };
}

/// One generation: the manifest naming the entries and source roots, the output tree, the cache directory and the
/// partition count. Without `write` it only analyzes, leaving the output as it is.
pub const Request = compiler.resident_protocol.Request;

/// Runs `request` and returns its summary line, or nothing when the output is already current.
pub fn generate(io: std.Io, allocator: std.mem.Allocator, resident: *Resident, request: Request) ![]const u8 {
    const manifest_source = try std.Io.Dir.cwd().readFileAlloc(io, request.manifest, allocator, .unlimited);
    const project = try std.json.parseFromSliceLeaky(manifest.Project, allocator, manifest_source, .{});
    const output = request.output;
    const partitions = request.partitions;

    if (project.entries.len == 0) return error.EmptyEntrySet;

    const owned = resident.inputAllocator(allocator);
    const snapshot = if (request.write) try InputSnapshot.prepare(io, allocator, owned, &resident.files, resident.digest, project, manifest_source, partitions, request.cache) else null;
    const recorded = if (request.write) try std.fs.path.join(allocator, &.{ output, publication.stamp_name }) else null;

    if (snapshot) |prepared| if (prepared.fingerprint) |digest| {
        if (try current(io, recorded.?, &digest)) return "";
    };

    var documents: std.ArrayList(collection.Document) = .empty;

    if (snapshot) |prepared| {
        try prepared.load(io, allocator, owned, &resident.files, &documents);
    } else for (project.roots) |root| try collection.collect(io, allocator, owned, &resident.files, root.path, root.prefix, &documents);

    const packages = try owned.alloc(compiler.project.Package, project.packages.len);

    for (project.packages, packages) |package, *target| {
        target.* = .{ .specifier = try resident.retainText(owned, package.specifier), .entry = try resident.retainText(owned, package.entry) };
    }

    const inputs = try collection.publish(allocator, owned, documents.items, packages, true);
    const interfaces = try @import("interface_inputs.zig").load(io, allocator, owned, resident, project.interfaces, inputs.sources);
    const rx_digests = try owned.alloc(analysis.project.ModuleDigest, inputs.modules.len);

    for (inputs.modules, rx_digests) |module, *item| item.* = .{ .path = module.path, .digest = resident.files.digest(module.path, module.source) };

    const frame = fingerprint.frame(&resident.digest, manifest_source, rx_digests, interfaces.bindings);
    const inputs_digest = if (recorded != null) outputDigest(&frame.content, partitions, inputs.sources, inputs.templates, &resident.files) else null;

    if (recorded) |path| {
        if (interfaces.failure == null and try current(io, path, &inputs_digest.?)) {
            try saveSnapshot(snapshot.?, io, &resident.files, inputs_digest.?);

            return "";
        }

        std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    const prepared_sources = switch (try compiler.project.prepareSources(owned, inputs.sources, .{ .entry = "" })) {
        .sources => |items| items,
        .diagnostic => |issue| {
            std.debug.print("{s}: {s}\n", .{ inputs.sources[issue.source_index.?].path, issue.message });

            return error.InvalidTemplateResource;
        },
    };

    const modules = try resident.modules.prepare(owned, inputs.modules, fingerprint.packages(packages));

    if (interfaces.failure) |err| return err;

    const summary = try @import("shared_generation.zig").run(io, allocator, owned, resident, project.entries, .{
        .modules = modules,
        .sources = prepared_sources,
        .interfaces = interfaces.bindings[0..interfaces.external],
        .internal_modules = interfaces.bindings[interfaces.external..],
        .packages = packages,
        .frame = frame.content,
        .shape = frame.shape,
        .rx_digests = rx_digests,
    }, if (request.write) output else null, request.cache, partitions);

    if (recorded) |path| {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = &publication.stamp(&inputs_digest.?) });
        try saveSnapshot(snapshot.?, io, &resident.files, inputs_digest.?);
    }

    return summary;
}

fn saveSnapshot(snapshot: InputSnapshot, io: std.Io, files: *Files, digest: fingerprint.Digest) !void {
    snapshot.save(io, files, digest) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
}

/// The frame and raw ZX/template inputs; a matching output needs no template expansion or RX parsing.
fn outputDigest(frame: *const fingerprint.Digest, partitions: u32, sources: []const compiler.project.Source, templates: []const compiler.project.Resource, files: *Files) fingerprint.Digest {
    var buffer: [1024]u8 = undefined;
    var hash = fingerprint.Hash.init(&buffer);

    fingerprint.output(&hash, frame, partitions);
    writeDigests(&hash, files, sources);
    writeDigests(&hash, files, templates);

    return hash.finish();
}

fn writeDigests(hash: *fingerprint.Hash, files: *Files, inputs: anytype) void {
    const batch_size = fingerprint.batch_size;
    var digests: [batch_size]fingerprint.Digest = undefined;
    var remaining = inputs;

    while (remaining.len != 0) {
        const count = @min(batch_size, remaining.len);

        for (remaining[0..count], digests[0..count]) |*input, *digest|
            digest.* = files.digest(input.path, input.source);

        fingerprint.files(hash, remaining[0..count], digests[0..count]);

        remaining = remaining[count..];
    }
}

fn current(io: std.Io, path: []const u8, digest: *const fingerprint.Digest) !bool {
    var buffer: [publication.stamp_width + 1]u8 = undefined;

    const recorded = std.Io.Dir.cwd().readFile(io, path, &buffer) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };

    return recorded.len == publication.stamp_width and std.mem.eql(u8, recorded, &publication.stamp(digest));
}
