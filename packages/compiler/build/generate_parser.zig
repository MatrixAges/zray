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
pub const resolveNative = compiler.native_lookup.Resolver(&.{ @This(), Generation, InputSnapshot, interface_inputs, collection }).resolve;

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

    const input: std.meta.Child(workflow.Input) = .{
        .request = @ptrCast(&frame),
        .write = request.write,
        .roots = project.roots.len,
    };

    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    return workflow.executeIn(arena.allocator(), &input) catch |err| return frame.failure orelse err;
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
    fn borrow(handle: *anyopaque) *Generation {
        return @ptrCast(@alignCast(handle));
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
    fn loadRoot(self: *Generation, row: usize, observed: bool) !void {
        const files = &self.resident.files;

        if (observed) return self.snapshot.loadRoot(self.io, self.allocator, files, row, &self.documents);

        const root = self.project.roots[row];

        try collection.collect(self.io, self.allocator, self.owned, files, root.path, root.prefix, &self.documents);
    }
    fn preparePackages(self: *Generation) !void {
        const packages = try self.owned.alloc(compiler.project.Package, self.project.packages.len);

        if (comptime generated) {
            const rule = @import("generated_generation_packages");
            const memory = @import("zx").memory;
            const Input = std.meta.Child(rule.Input);
            const fields = .{ .specifiers = "specifier", .entries = "entry" };
            const source = memory.borrowReadFields(fields, self.project.packages);

            const result = try rule.executeIn(self.owned, &.{
                .fields = &source.bind(std.meta.Child(@FieldType(Input, "fields"))),
                .retain = self.resident.request != null,
            });

            for (result, packages) |item, *slot| {
                slot.* = .{ .specifier = item.specifier, .entry = item.entry };
            }
        } else {
            for (self.project.packages, packages) |package, *slot| {
                slot.* = .{
                    .specifier = try self.resident.retainText(self.owned, package.specifier),
                    .entry = try self.resident.retainText(self.owned, package.entry),
                };
            }
        }

        self.packages = packages;
    }

    fn classify(self: *Generation) !void {
        self.inputs = try collection.publish(self.allocator, self.owned, self.documents.items, self.packages, true);
    }

    fn registerInterfaces(self: *Generation) !void {
        self.interfaces = try interface_inputs.load(self.io, self.allocator, self.owned, self.resident, self.project.interfaces, self.inputs.sources);
    }

    fn prepareFingerprints(self: *Generation) !void {
        const resident = self.resident;
        const digests = try self.owned.alloc(analysis.project.ModuleDigest, self.inputs.modules.len);

        self.rx_digests = digests;

        self.fingerprints = if (comptime generated) try self.hashFrame(digests) else seed: {
            for (self.inputs.modules, digests) |module, *item| {
                item.* = .{ .path = module.path, .digest = resident.files.digest(module.path, module.source) };
            }

            break :seed fingerprint.seedFrame(&resident.digest, self.manifest_source, digests, self.interfaces.bindings);
        };

        self.digest = try self.outputDigest();
    }

    fn hashFrame(self: *const Generation, digests: []analysis.project.ModuleDigest) !fingerprint.Frame {
        const rule = @import("generated_input_frame_fingerprint");
        const memory = @import("zx").memory;
        const paths = memory.borrowTextColumn("path", self.inputs.modules);
        const interfaces = memory.borrowTextColumn("source", self.interfaces.bindings);
        var arena = std.heap.ArenaAllocator.init(self.allocator);

        defer arena.deinit();

        const result = try rule.executeIn(arena.allocator(), &.{
            .generator = &self.resident.digest,
            .manifest = self.manifest_source,
            .modules = &.{
                .paths = @ptrCast(&paths),
                .digests = try fileDigests(&self.resident.files, arena.allocator(), self.inputs.modules),
            },
            .interfaces = @ptrCast(&interfaces),
            .interface_count = self.interfaces.bindings.len,
        });

        for (result.digests, digests) |row, *item| {
            std.debug.assert(row.digest.len == @sizeOf(fingerprint.Digest));

            item.* = .{ .path = row.path, .digest = row.digest[0..@sizeOf(fingerprint.Digest)].* };
        }

        std.debug.assert(result.content.len == @sizeOf(fingerprint.Digest));
        std.debug.assert(result.shape.len == @sizeOf(fingerprint.Digest));

        return .{
            .content = result.content[0..@sizeOf(fingerprint.Digest)].*,
            .shape = result.shape[0..@sizeOf(fingerprint.Digest)].*,
        };
    }

    fn outputDigest(self: *const Generation) !fingerprint.Digest {
        const frame = &self.fingerprints.content;
        const partitions = self.request.partitions;
        const files = &self.resident.files;

        if (comptime !generated) return fingerprint.seedOutput(frame, partitions, self.inputs.sources, self.inputs.templates, files);

        const rule = @import("generated_input_output_fingerprint");
        const memory = @import("zx").memory;
        const sources = memory.borrowTextColumn("path", self.inputs.sources);
        const templates = memory.borrowTextColumn("path", self.inputs.templates);
        var arena = std.heap.ArenaAllocator.init(self.allocator);

        defer arena.deinit();

        const digest = try rule.executeIn(arena.allocator(), &.{
            .frame = frame,
            .partitions = partitions,
            .sources = &.{
                .paths = @ptrCast(&sources),
                .digests = try fileDigests(files, arena.allocator(), self.inputs.sources),
            },
            .templates = &.{
                .paths = @ptrCast(&templates),
                .digests = try fileDigests(files, arena.allocator(), self.inputs.templates),
            },
        });

        std.debug.assert(digest.len == @sizeOf(fingerprint.Digest));

        return digest[0..@sizeOf(fingerprint.Digest)].*;
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
        self.modules = try self.resident.modules.prepare(self.owned, self.inputs.modules, try fingerprint.packages(self.allocator, self.packages));
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
        }

        for (self.project.roots, 0..) |_, row| try self.loadRoot(row, self.request.write);
        try self.preparePackages();
        try self.classify();
        try self.registerInterfaces();
        try self.prepareFingerprints();

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

    fn effect(comptime method: anytype) type {
        const Return = @typeInfo(@TypeOf(method)).@"fn".return_type.?;
        const Output = @typeInfo(Return).error_union.payload;

        return struct {
            fn invoke(handle: *anyopaque) Error!Output {
                const self = borrow(handle);

                return method(self) catch |err| self.fail(err);
            }
        };
    }

    pub const observeGenerationInputs = effect(observe).invoke;
    pub const retainGenerationPackages = effect(preparePackages).invoke;
    pub const classifyGenerationDocuments = effect(classify).invoke;
    pub const registerGenerationInterfaces = effect(registerInterfaces).invoke;
    pub const readGenerationStamp = effect(readStamp).invoke;
    pub const invalidateGenerationStamp = effect(invalidateStamp).invoke;
    pub const prepareGenerationTemplates = effect(prepareTemplates).invoke;
    pub const prepareGenerationModules = effect(prepareModules).invoke;
    pub const generateFromPreparedInputs = effect(emit).invoke;
    pub const writeGenerationStamp = effect(writeStamp).invoke;
    pub const saveGenerationSnapshot = effect(saveSnapshot).invoke;

    pub fn loadGenerationRoot(handle: *anyopaque, row: u64, observed: bool) Error!void {
        const self = borrow(handle);

        self.loadRoot(@intCast(row), observed) catch |err| return self.fail(err);
    }

    pub fn fingerprintGenerationInputs(handle: *anyopaque) Error!*const Prepared {
        const self = borrow(handle);

        self.prepareFingerprints() catch |err| return self.fail(err);

        const interfaces_loaded = self.interfaces.failure == null;

        self.previous = if (interfaces_loaded) self.resident.exactAnalysis(&self.digest) else null;

        self.prepared = .{
            .digest = &self.digest,
            .interfaces_loaded = interfaces_loaded,
            .analysis_available = self.previous != null,
        };

        return &self.prepared;
    }
    pub fn restoreGenerationAnalysis(handle: *anyopaque) Error![]const u8 {
        const self = borrow(handle);

        return generation.restore(self.target(), self.previous.?, self.project.entries.len) catch |err| self.fail(err);
    }
    pub fn checkGenerationInterfaces(handle: *anyopaque) Error!void {
        const self = borrow(handle);

        if (self.interfaces.failure) |err| return self.fail(err);
    }
};

fn fileDigests(files: *Files, allocator: std.mem.Allocator, rows: anytype) ![]const []const u8 {
    const values = try allocator.alloc(fingerprint.Digest, rows.len);
    const digests = try allocator.alloc([]const u8, rows.len);

    for (rows, values, digests) |row, *value, *digest| {
        value.* = files.digest(row.path, row.source);
        digest.* = value;
    }

    return digests;
}
