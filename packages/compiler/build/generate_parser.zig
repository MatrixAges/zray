const std = @import("std");
const compiler = @import("compiler");
const analysis = @import("rx_analysis");
const collection = @import("source_collection.zig");
const manifest = @import("generation_manifest.zig");
const interface_inputs = @import("interface_inputs.zig");
const Resident = @import("resident/state.zig");
const Files = @import("resident/files.zig");
const InputSnapshot = @import("input_snapshot.zig");
const fingerprint = compiler.input_fingerprint;
const publication = compiler.input_generation;
const generation = @import("shared_generation.zig");
const generated = publication.generated;
const Prepared = if (generated) @import("generation_execution_abi").layouts.@"zig:generation_host".PreparedGeneration else void;
pub const resolveNative = compiler.native_lookup.Resolver(&.{ @This(), Generation }).resolve;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const kind = compiler.resident_protocol.command(args);

    return switch (kind) {
        .Missing => error.MissingCommand,
        .Unknown => error.UnknownCommand,
        .Incomplete => error.OutputCountMismatch,
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

    if (project.entries.len == 0) return error.EmptyEntrySet;

    var frame: Generation = .{
        .io = io,
        .allocator = allocator,
        .owned = resident.inputAllocator(allocator),
        .resident = resident,
        .request = request,
        .manifest_source = manifest_source,
        .project = project,
    };

    if (comptime !generated) return frame.seed();

    const workflow = @import("generated_generation_request");
    const input: std.meta.Child(workflow.Input) = .{ .request = @ptrCast(&frame), .write = request.write };
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return workflow.executeIn(empty.allocator(), &input) catch |err| return frame.failure orelse err;
}

const Generation = struct {
    const Error = error{GenerationRequestFailed};
    io: std.Io,
    allocator: std.mem.Allocator,
    owned: std.mem.Allocator,
    resident: *Resident,
    request: Request,
    manifest_source: []const u8,
    project: manifest.Project,
    documents: std.ArrayList(collection.Document) = .empty,
    snapshot: InputSnapshot = undefined,
    stamp_path: []const u8 = undefined,
    stamp_buffer: [publication.stamp_width + 1]u8 = undefined,
    encoded_stamp: publication.Stamp = undefined,
    packages: []const compiler.project.Package = undefined,
    inputs: collection.Catalog = undefined,
    interfaces: interface_inputs.Result = undefined,
    rx_digests: []const analysis.project.ModuleDigest = undefined,
    fingerprints: fingerprint.Frame = undefined,
    digest: fingerprint.Digest = undefined,
    prepared: Prepared = undefined,
    previous: ?Resident.Restored = null,
    sources: []const compiler.project.Source = undefined,
    modules: []const @import("rx").ModuleSource = undefined,
    failure: ?anyerror = null,
    fn borrow(handle: *const anyopaque) *Generation {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
    fn fail(self: *Generation, err: anyerror) Error {
        self.failure = err;

        return error.GenerationRequestFailed;
    }

    fn target(self: *const Generation) generation.Target {
        return .{
            .io = self.io,
            .allocator = self.allocator,
            .resident = self.resident,
            .output = if (self.request.write) self.request.output else null,
            .cache_path = self.request.cache,
            .partitions = self.request.partitions,
        };
    }
    fn observe(self: *Generation) !?[]const u8 {
        self.snapshot = try InputSnapshot.prepare(self.io, self.allocator, self.owned, &self.resident.files, self.resident.digest, self.project, self.manifest_source, self.request.partitions, self.request.cache);
        self.stamp_path = try std.fs.path.join(self.allocator, &.{ self.request.output, publication.stamp_name });

        return if (self.snapshot.fingerprint) |*digest| digest else null;
    }
    fn load(self: *Generation, comptime observed: bool) !void {
        if (observed) {
            return self.snapshot.load(self.io, self.allocator, self.owned, &self.resident.files, &self.documents);
        }

        for (self.project.roots) |root| {
            try collection.collect(self.io, self.allocator, self.owned, &self.resident.files, root.path, root.prefix, &self.documents);
        }
    }
    fn prepare(self: *Generation) !void {
        const resident = self.resident;
        const packages = try self.owned.alloc(compiler.project.Package, self.project.packages.len);

        for (self.project.packages, packages) |package, *slot| {
            slot.* = .{ .specifier = try resident.retainText(self.owned, package.specifier), .entry = try resident.retainText(self.owned, package.entry) };
        }

        self.packages = packages;
        self.inputs = try collection.publish(self.allocator, self.owned, self.documents.items, packages, true);
        self.interfaces = try interface_inputs.load(self.io, self.allocator, self.owned, resident, self.project.interfaces, self.inputs.sources);

        const digests = try self.owned.alloc(analysis.project.ModuleDigest, self.inputs.modules.len);

        for (self.inputs.modules, digests) |module, *item| item.* = .{ .path = module.path, .digest = resident.files.digest(module.path, module.source) };

        self.rx_digests = digests;
        self.fingerprints = fingerprint.frame(&resident.digest, self.manifest_source, digests, self.interfaces.bindings);
        self.digest = outputDigest(&self.fingerprints.content, self.request.partitions, self.inputs.sources, self.inputs.templates, &resident.files);
    }

    fn readStamp(self: *Generation) !?[]const u8 {
        return std.Io.Dir.cwd().readFile(self.io, self.stamp_path, &self.stamp_buffer) catch |err| switch (err) {
            error.FileNotFound => null,
            else => err,
        };
    }

    fn invalidateStamp(self: *const Generation) !void {
        std.Io.Dir.cwd().deleteFile(self.io, self.stamp_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    fn prepareTemplates(self: *Generation) !void {
        self.sources = switch (try compiler.project.prepareSources(self.owned, self.inputs.sources, .{ .entry = "" })) {
            .sources => |items| items,
            .diagnostic => |issue| {
                std.debug.print("{s}: {s}\n", .{ self.inputs.sources[issue.source_index.?].path, issue.message });

                return error.InvalidTemplateResource;
            },
        };
    }

    fn prepareModules(self: *Generation) !void {
        self.modules = try self.resident.modules.prepare(self.owned, self.inputs.modules, fingerprint.packages(self.packages));
    }

    fn emit(self: *Generation) ![]const u8 {
        return generation.run(self.target(), self.owned, self.project.entries, .{
            .modules = self.modules,
            .sources = self.sources,
            .interfaces = self.interfaces.bindings[0..self.interfaces.external],
            .internal_modules = self.interfaces.bindings[self.interfaces.external..],
            .packages = self.packages,
            .frame = self.fingerprints.content,
            .shape = self.fingerprints.shape,
            .rx_digests = self.rx_digests,
            .fingerprint = self.digest,
        });
    }
    fn writeStamp(self: *const Generation) !void {
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = self.stamp_path, .data = &publication.stamp(&self.digest) });
    }
    fn saveSnapshot(self: *const Generation) !void {
        self.snapshot.save(self.io, &self.resident.files, self.digest) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        };
    }

    fn seedStampMatches(self: *Generation, digest: *const fingerprint.Digest) !bool {
        const recorded = try self.readStamp() orelse return false;

        return recorded.len == publication.stamp_width and std.mem.eql(u8, recorded, &publication.stamp(digest));
    }
    fn seed(self: *Generation) ![]const u8 {
        if (self.request.write) {
            if (try self.observe()) |digest| {
                if (try self.seedStampMatches(digest[0..@sizeOf(fingerprint.Digest)])) return "";
            }

            try self.load(true);
        } else {
            try self.load(false);
        }

        try self.prepare();

        if (self.request.write) {
            if (self.interfaces.failure == null and try self.seedStampMatches(&self.digest)) {
                try self.saveSnapshot();

                return "";
            }

            try self.invalidateStamp();
        }

        const previous = if (self.interfaces.failure == null) self.resident.exactAnalysis(&self.digest) else null;

        const summary = if (previous) |saved| try generation.restore(self.target(), saved, self.project.entries.len) else fresh: {
            try self.prepareTemplates();
            try self.prepareModules();
            if (self.interfaces.failure) |err| return err;

            break :fresh try self.emit();
        };

        if (self.request.write) {
            try self.writeStamp();
            try self.saveSnapshot();
        }

        return summary;
    }
    pub fn observeGenerationInputs(handle: *const anyopaque) Error!?[]const u8 {
        const self = borrow(handle);

        return self.observe() catch |err| self.fail(err);
    }
    pub fn loadObservedSources(handle: *const anyopaque) Error!void {
        const self = borrow(handle);

        self.load(true) catch |err| return self.fail(err);
    }

    pub fn collectGenerationSources(handle: *const anyopaque) Error!void {
        const self = borrow(handle);

        self.load(false) catch |err| return self.fail(err);
    }

    pub fn prepareGenerationInputs(handle: *const anyopaque) Error!*const Prepared {
        const self = borrow(handle);

        self.prepare() catch |err| return self.fail(err);

        self.prepared = .{ .digest = &self.digest, .interfaces_loaded = self.interfaces.failure == null };

        return &self.prepared;
    }
    pub fn readGenerationStamp(handle: *const anyopaque) Error!?[]const u8 {
        const self = borrow(handle);

        return self.readStamp() catch |err| self.fail(err);
    }
    pub fn formatGenerationStamp(handle: *const anyopaque, digest: []const u8) []const u8 {
        const self = borrow(handle);

        self.encoded_stamp = publication.stamp(digest[0..@sizeOf(fingerprint.Digest)]);

        return &self.encoded_stamp;
    }
    pub fn invalidateGenerationStamp(handle: *const anyopaque) Error!void {
        const self = borrow(handle);

        self.invalidateStamp() catch |err| return self.fail(err);
    }

    pub fn lookupGenerationAnalysis(handle: *const anyopaque) bool {
        const self = borrow(handle);

        self.previous = self.resident.exactAnalysis(&self.digest);

        return self.previous != null;
    }
    pub fn restoreGenerationAnalysis(handle: *const anyopaque) Error![]const u8 {
        const self = borrow(handle);

        return generation.restore(self.target(), self.previous.?, self.project.entries.len) catch |err| self.fail(err);
    }
    pub fn prepareGenerationTemplates(handle: *const anyopaque) Error!void {
        const self = borrow(handle);

        self.prepareTemplates() catch |err| return self.fail(err);
    }

    pub fn prepareGenerationModules(handle: *const anyopaque) Error!void {
        const self = borrow(handle);

        self.prepareModules() catch |err| return self.fail(err);
    }

    pub fn checkGenerationInterfaces(handle: *const anyopaque) Error!void {
        const self = borrow(handle);

        if (self.interfaces.failure) |err| return self.fail(err);
    }
    pub fn generateFromPreparedInputs(handle: *const anyopaque) Error![]const u8 {
        const self = borrow(handle);

        return self.emit() catch |err| self.fail(err);
    }
    pub fn writeGenerationStamp(handle: *const anyopaque) Error!void {
        const self = borrow(handle);

        self.writeStamp() catch |err| return self.fail(err);
    }

    pub fn saveGenerationSnapshot(handle: *const anyopaque) Error!void {
        const self = borrow(handle);

        self.saveSnapshot() catch |err| return self.fail(err);
    }
};

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
