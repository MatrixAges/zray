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
const Host = if (generated) @import("generation_execution_abi").native.@"zig:generation_host" else void;
pub const resolveNative = compiler.native_lookup.Resolver(&.{ @This(), collection }).resolve;

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

    var failure: ?anyerror = null;

    const context: GenerationIO = .{
        .allocator = allocator,
        .owned = resident.inputAllocator(allocator),
        .resident = resident,
        .request = request,
        .manifest_source = manifest_source,
        .project = project,
        .failure = &failure,
    };

    const stamp_path = if (request.write) try std.fs.path.join(allocator, &.{ request.output, publication.stamp_name }) else "";

    if (comptime !generated) return context.seed(io, stamp_path);

    const workflow = @import("generated_generation_request");
    const Input = std.meta.Child(workflow.Input);
    const columns = @import("zx").memory.borrowReadFields(.{ .specifiers = "specifier", .entries = "entry" }, project.packages);
    const packages = columns.bind(std.meta.Child(@FieldType(Input, "packages")));

    const input: Input = .{
        .packages = &packages,
        .host = @ptrCast(&context),
        .write = request.write,
        .stamp_path = stamp_path,
        .roots = project.roots.len,
    };

    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const Documents = std.meta.Child(@FieldType(workflow.zx_pending, "store_0"));
    const initial: std.meta.Child(Documents) = .{ .batches = &.{} };
    var documents: Documents = &initial;

    var stores = struct {
        store_0: *Documents,
        pub fn commit(self: *@This(), pending: workflow.zx_pending) error{}!void {
            if (pending.store_0) |next| self.store_0.* = next;
        }
    }{ .store_0 = &documents };

    const result = workflow.executeIn(arena.allocator(), &input, &stores, io) catch |err| return failure orelse err;

    if (result.failure) |code| return @errorFromInt(code);

    return result.text.?;
}

const Error = error{GenerationRequestFailed};

const PreparedCatalog = struct {
    inputs: collection.Catalog,
    packages: []const compiler.project.Package,
};

const Digests = struct {
    frame: fingerprint.Frame,
    modules: []const analysis.project.ModuleDigest,
    output: fingerprint.Digest,
};

/// Borrowed platform services and manifest inputs for one invocation.
const GenerationIO = struct {
    allocator: std.mem.Allocator,
    owned: std.mem.Allocator,
    resident: *Resident,
    request: Request,
    manifest_source: []const u8,
    project: manifest.Project,
    // Keeps the concrete Zig error across the generated interface's fixed error set.
    failure: *?anyerror,
    fn fail(self: *const GenerationIO, err: anyerror) Error {
        self.failure.* = err;

        return error.GenerationRequestFailed;
    }
    fn target(self: *const GenerationIO, io: std.Io) generation.Target {
        return .{
            .io = io,
            .allocator = self.allocator,
            .resident = self.resident,
            .output = if (self.request.write) self.request.output else null,
            .cache_path = self.request.cache,
            .partitions = self.request.partitions,
        };
    }
    fn observe(self: *const GenerationIO, io: std.Io) !InputSnapshot {
        return InputSnapshot.prepare(io, self.allocator, self.owned, &self.resident.files, self.resident.digest, self.project, self.manifest_source, self.request.partitions, self.request.cache);
    }
    fn loadRoot(self: *const GenerationIO, io: std.Io, row: usize, snapshot: ?*const InputSnapshot, documents: *std.ArrayList(collection.Document)) !void {
        const files = &self.resident.files;

        if (snapshot) |observed| return observed.loadRoot(io, self.allocator, files, row, documents);

        const root = self.project.roots[row];

        try collection.collect(io, self.allocator, self.owned, files, root.path, root.prefix, documents);
    }
    fn classify(self: *const GenerationIO, allocator: std.mem.Allocator, documents: []const collection.Document, packages: []const compiler.project.Package) !collection.Catalog {
        return collection.publish(allocator, self.owned, documents, packages, true);
    }
    fn register(self: *const GenerationIO, io: std.Io, allocator: std.mem.Allocator, inputs: collection.Catalog) !interface_inputs.Result {
        return interface_inputs.load(io, allocator, self.owned, self.resident, self.project.interfaces, inputs.sources);
    }
    fn prepareFingerprints(self: *const GenerationIO, inputs: collection.Catalog, bindings: []const compiler.project.NativeInterface) !Digests {
        const resident = self.resident;
        const digests = try self.owned.alloc(analysis.project.ModuleDigest, inputs.modules.len);

        const frame = if (comptime generated) try self.hashFrame(inputs, bindings, digests) else seed: {
            for (inputs.modules, digests) |module, *item| {
                item.* = .{ .path = module.path, .digest = resident.files.digest(module.path, module.source) };
            }

            break :seed fingerprint.seedFrame(&resident.digest, self.manifest_source, digests, bindings);
        };

        return .{
            .frame = frame,
            .modules = digests,
            .output = try self.outputDigest(inputs, &frame.content),
        };
    }
    fn retainPackages(self: *const GenerationIO, rows: anytype) ![]const compiler.project.Package {
        const packages = try self.owned.alloc(compiler.project.Package, rows.len);

        for (rows, packages) |row, *slot| {
            slot.* = .{
                .specifier = try self.resident.retainText(self.owned, row.specifier),
                .entry = try self.resident.retainText(self.owned, row.entry),
            };
        }

        return packages;
    }
    fn hashFrame(self: *const GenerationIO, inputs: collection.Catalog, bindings: []const compiler.project.NativeInterface, digests: []analysis.project.ModuleDigest) !fingerprint.Frame {
        const rule = @import("generated_input_frame_fingerprint");
        const memory = @import("zx").memory;
        const paths = memory.borrowTextColumn("path", inputs.modules);
        const interfaces = memory.borrowTextColumn("source", bindings);
        var arena = std.heap.ArenaAllocator.init(self.allocator);

        defer arena.deinit();

        const result = try rule.executeIn(arena.allocator(), &.{
            .generator = &self.resident.digest,
            .manifest = self.manifest_source,
            .modules = &.{
                .paths = @ptrCast(&paths),
                .digests = try fileDigests(&self.resident.files, arena.allocator(), inputs.modules),
            },
            .interfaces = @ptrCast(&interfaces),
            .interface_count = bindings.len,
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

    fn outputDigest(self: *const GenerationIO, inputs: collection.Catalog, frame: *const fingerprint.Digest) !fingerprint.Digest {
        const partitions = self.request.partitions;
        const files = &self.resident.files;

        if (comptime !generated) return fingerprint.seedOutput(frame, partitions, inputs.sources, inputs.templates, files);

        const rule = @import("generated_input_output_fingerprint");
        const memory = @import("zx").memory;
        const sources = memory.borrowTextColumn("path", inputs.sources);
        const templates = memory.borrowTextColumn("path", inputs.templates);
        var arena = std.heap.ArenaAllocator.init(self.allocator);

        defer arena.deinit();

        const digest = try rule.executeIn(arena.allocator(), &.{
            .frame = frame,
            .partitions = partitions,
            .sources = &.{
                .paths = @ptrCast(&sources),
                .digests = try fileDigests(files, arena.allocator(), inputs.sources),
            },
            .templates = &.{
                .paths = @ptrCast(&templates),
                .digests = try fileDigests(files, arena.allocator(), inputs.templates),
            },
        });

        std.debug.assert(digest.len == @sizeOf(fingerprint.Digest));

        return digest[0..@sizeOf(fingerprint.Digest)].*;
    }

    fn prepareTemplates(self: *const GenerationIO, inputs: collection.Catalog) ![]const compiler.project.Source {
        return switch (try compiler.project.prepareSources(self.owned, inputs.sources, .{ .entry = "" })) {
            .sources => |items| items,
            .diagnostic => |issue| {
                std.debug.print("{s}: {s}\n", .{ inputs.sources[issue.source_index.?].path, issue.message });

                return error.InvalidTemplateResource;
            },
        };
    }

    fn prepareModules(self: *const GenerationIO, inputs: collection.Catalog, packages: []const compiler.project.Package) ![]const @import("rx").ModuleSource {
        return self.resident.modules.prepare(self.owned, inputs.modules, try fingerprint.packages(self.allocator, packages));
    }
    fn emit(
        self: *const GenerationIO,
        io: std.Io,
        digests: Digests,
        packages: []const compiler.project.Package,
        interfaces: interface_inputs.Result,
        sources: []const compiler.project.Source,
        modules: []const @import("rx").ModuleSource,
    ) ![]const u8 {
        return generation.run(self.target(io), self.owned, self.project.entries, .{
            .modules = modules,
            .sources = sources,
            .interfaces = interfaces.bindings[0..interfaces.external],
            .internal_modules = interfaces.bindings[interfaces.external..],
            .packages = packages,
            .frame = digests.frame.content,
            .shape = digests.frame.shape,
            .rx_digests = digests.modules,
            .fingerprint = digests.output,
        });
    }

    fn saveSnapshot(self: *const GenerationIO, io: std.Io, snapshot: *const InputSnapshot, digest: fingerprint.Digest) !void {
        snapshot.save(io, &self.resident.files, digest) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        };
    }
    fn seed(self: *const GenerationIO, io: std.Io, stamp_path: []const u8) ![]const u8 {
        const snapshot = if (self.request.write) try self.observe(io) else null;

        if (snapshot) |observed| {
            if (observed.fingerprint) |*digest| {
                if (try seedStampMatches(io, stamp_path, digest)) return "";
            }
        }

        var documents: std.ArrayList(collection.Document) = .empty;

        for (self.project.roots, 0..) |_, row| try self.loadRoot(io, row, if (snapshot) |*observed| observed else null, &documents);

        const packages = try self.retainPackages(self.project.packages);
        const inputs = try self.classify(self.allocator, documents.items, packages);
        const interfaces = try self.register(io, self.allocator, inputs);
        const digests = try self.prepareFingerprints(inputs, interfaces.bindings);

        if (snapshot) |*observed| {
            if (interfaces.failure == null and try seedStampMatches(io, stamp_path, &digests.output)) {
                try self.saveSnapshot(io, observed, digests.output);

                return "";
            }

            try invalidateGenerationStamp(io, stamp_path);
        }

        const previous = if (interfaces.failure == null) self.resident.exactAnalysis(&digests.output) else null;

        const summary = if (previous) |saved| try generation.restore(self.target(io), saved, self.project.entries.len) else fresh: {
            const sources = try self.prepareTemplates(inputs);
            const modules = try self.prepareModules(inputs, packages);

            if (interfaces.failure) |err| return err;

            break :fresh try self.emit(io, digests, packages, interfaces, sources, modules);
        };

        if (snapshot) |*observed| {
            try writeGenerationStamp(io, stamp_path, &publication.stamp(&digests.output));
            try self.saveSnapshot(io, observed, digests.output);
        }

        return summary;
    }
};

pub fn observeGenerationInputs(allocator: std.mem.Allocator, io: std.Io, reference: *const anyopaque) Error!Host.GenerationObservation {
    const host = borrow(GenerationIO, reference);
    const snapshot = try keep(host, allocator, host.observe(io) catch |err| return host.fail(err));

    return keep(host, allocator, @as(std.meta.Child(Host.GenerationObservation), .{
        .snapshot = @ptrCast(snapshot),
        .digest = if (snapshot.fingerprint) |*digest| digest else null,
    }));
}

pub fn loadGenerationRoot(io: std.Io, reference: *const anyopaque, row: u64, observed: ?*const anyopaque) Error![]const u8 {
    const host = borrow(GenerationIO, reference);
    const snapshot = if (observed) |value| borrow(InputSnapshot, value) else null;
    var documents: std.ArrayList(collection.Document) = .empty;

    host.loadRoot(io, @intCast(row), snapshot, &documents) catch |err| return host.fail(err);

    return std.mem.sliceAsBytes(documents.items);
}

pub fn classifyGenerationDocuments(allocator: std.mem.Allocator, reference: *const anyopaque, batches: []const []const u8, package_rows: []const Host.GenerationPackage) Error!Host.GenerationArtifact {
    const host = borrow(GenerationIO, reference);
    const packages = host.retainPackages(package_rows) catch |err| return host.fail(err);
    const documents = collectDocuments(allocator, batches) catch |err| return host.fail(err);
    const inputs = host.classify(allocator, documents, packages) catch |err| return host.fail(err);

    return @ptrCast(try keep(host, allocator, PreparedCatalog{ .inputs = inputs, .packages = packages }));
}

pub fn registerGenerationInterfaces(allocator: std.mem.Allocator, io: std.Io, reference: *const anyopaque, catalog: *const anyopaque) Error!Host.GenerationRegistration {
    const host = borrow(GenerationIO, reference);
    const prepared = borrow(PreparedCatalog, catalog);
    const bindings = try keep(host, allocator, host.register(io, allocator, prepared.inputs) catch |err| return host.fail(err));

    return keep(host, allocator, @as(std.meta.Child(Host.GenerationRegistration), .{
        .bindings = @ptrCast(bindings),
        .failure = if (bindings.failure) |err| @intFromError(err) else null,
    }));
}

pub fn fingerprintGenerationInputs(allocator: std.mem.Allocator, reference: *const anyopaque, catalog: *const anyopaque, interfaces: *const anyopaque, interfaces_loaded: bool) Error!Host.PreparedGeneration {
    const host = borrow(GenerationIO, reference);
    const prepared = borrow(PreparedCatalog, catalog);
    const bindings = borrow(interface_inputs.Result, interfaces);
    const digests = try keep(host, allocator, host.prepareFingerprints(prepared.inputs, bindings.bindings) catch |err| return host.fail(err));
    const previous = if (interfaces_loaded) host.resident.exactAnalysis(&digests.output) else null;

    return keep(host, allocator, @as(std.meta.Child(Host.PreparedGeneration), .{
        .digest = &digests.output,
        .fingerprints = @ptrCast(digests),
        .previous = if (previous) |saved| @ptrCast(try keep(host, allocator, saved)) else null,
    }));
}

pub fn restoreGenerationAnalysis(io: std.Io, reference: *const anyopaque, previous: *const anyopaque) Error![]const u8 {
    const host = borrow(GenerationIO, reference);
    const saved = borrow(Resident.Restored, previous);

    return generation.restore(host.target(io), saved.*, host.project.entries.len) catch |err| host.fail(err);
}

pub fn prepareGenerationTemplates(allocator: std.mem.Allocator, reference: *const anyopaque, catalog: *const anyopaque) Error!Host.GenerationArtifact {
    const host = borrow(GenerationIO, reference);
    const prepared = borrow(PreparedCatalog, catalog);
    const sources = host.prepareTemplates(prepared.inputs) catch |err| return host.fail(err);

    return @ptrCast(try keep(host, allocator, sources));
}

pub fn prepareGenerationModules(allocator: std.mem.Allocator, reference: *const anyopaque, catalog: *const anyopaque) Error!Host.GenerationArtifact {
    const host = borrow(GenerationIO, reference);
    const prepared = borrow(PreparedCatalog, catalog);
    const modules = host.prepareModules(prepared.inputs, prepared.packages) catch |err| return host.fail(err);

    return @ptrCast(try keep(host, allocator, modules));
}

pub fn generateFromPreparedInputs(io: std.Io, reference: *const anyopaque, digests: *const anyopaque, catalog: *const anyopaque, interfaces: *const anyopaque, sources: *const anyopaque, modules: *const anyopaque) Error![]const u8 {
    const host = borrow(GenerationIO, reference);
    const ready = borrow(Digests, digests);
    const prepared = borrow(PreparedCatalog, catalog);
    const bindings = borrow(interface_inputs.Result, interfaces);
    const source_rows = borrow([]const compiler.project.Source, sources);
    const module_rows = borrow([]const @import("rx").ModuleSource, modules);

    return host.emit(io, ready.*, prepared.packages, bindings.*, source_rows.*, module_rows.*) catch |err| host.fail(err);
}

pub fn saveGenerationSnapshot(io: std.Io, reference: *const anyopaque, observed: *const anyopaque, digest: []const u8) Error!void {
    const host = borrow(GenerationIO, reference);
    const snapshot = borrow(InputSnapshot, observed);

    return host.saveSnapshot(io, snapshot, digest[0..@sizeOf(fingerprint.Digest)].*) catch |err| host.fail(err);
}

fn borrow(comptime T: type, reference: *const anyopaque) *const T {
    return @ptrCast(@alignCast(reference));
}

fn keep(host: *const GenerationIO, allocator: std.mem.Allocator, value: anytype) Error!*const @TypeOf(value) {
    const slot = allocator.create(@TypeOf(value)) catch |err| return host.fail(err);

    slot.* = value;

    return slot;
}

fn collectDocuments(allocator: std.mem.Allocator, batches: []const []const u8) ![]const collection.Document {
    const alignment = @alignOf(collection.Document);

    if (batches.len == 1 and std.mem.isAligned(@intFromPtr(batches[0].ptr), alignment)) {
        const aligned: []align(alignment) const u8 = @alignCast(batches[0]);

        return std.mem.bytesAsSlice(collection.Document, aligned);
    }

    var count: usize = 0;

    for (batches) |batch| count += batch.len / @sizeOf(collection.Document);

    const documents = try allocator.alloc(collection.Document, count);
    const output = std.mem.sliceAsBytes(documents);
    var offset: usize = 0;

    for (batches) |batch| {
        @memcpy(output[offset..][0..batch.len], batch);

        offset += batch.len;
    }

    return documents;
}

fn seedStampMatches(io: std.Io, path: []const u8, digest: *const fingerprint.Digest) !bool {
    var buffer: [publication.stamp_width + 1]u8 = undefined;
    const recorded = try readStamp(io, path, &buffer) orelse return false;

    return recorded.len == publication.stamp_width and std.mem.eql(u8, recorded, &publication.stamp(digest));
}

fn readStamp(io: std.Io, path: []const u8, buffer: []u8) !?[]const u8 {
    return std.Io.Dir.cwd().readFile(io, path, buffer) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

pub fn readGenerationStamp(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?[]const u8 {
    const buffer = try allocator.alloc(u8, publication.stamp_width + 1);

    errdefer allocator.free(buffer);

    if (try readStamp(io, path, buffer)) |recorded| return recorded;

    allocator.free(buffer);

    return null;
}

pub fn invalidateGenerationStamp(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn writeGenerationStamp(io: std.Io, path: []const u8, stamp: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = stamp });
}

fn fileDigests(files: *Files, allocator: std.mem.Allocator, rows: anytype) ![]const []const u8 {
    const values = try allocator.alloc(fingerprint.Digest, rows.len);
    const digests = try allocator.alloc([]const u8, rows.len);

    for (rows, values, digests) |row, *value, *digest| {
        value.* = files.digest(row.path, row.source);
        digest.* = value;
    }

    return digests;
}
