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
pub const resolveNative = compiler.native_lookup.Resolver(&.{@This()}).resolve;

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
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const scratch = arena.allocator();
    const now = compiler.input_snapshot.timestamp(std.Io.Timestamp.now(io, .real).nanoseconds);

    const input: Input = .{
        .packages = &packages,
        .host = @ptrCast(&context),
        .write = request.write,
        .stamp_path = stamp_path,
        .roots = try generationRoots(scratch, project.roots),
        .interfaces = try generationInterfaces(scratch, project.interfaces),
        .generator = &resident.digest,
        .manifest = manifest_source,
        .partitions = request.partitions,
        .cache = request.cache,
        .cwd = if (request.write) try std.process.currentPathAlloc(io, scratch) else "",
        .now = &.{ .high = now.high, .low = now.low },
    };

    const Entries = std.meta.Child(@FieldType(workflow.zx_pending, "store_0"));
    const Documents = std.meta.Child(@FieldType(workflow.zx_pending, "store_1"));
    const initial_entries: std.meta.Child(Entries) = .{ .levels = &.{} };
    const initial_documents: std.meta.Child(Documents) = .{ .batches = &.{} };
    var collected: Entries = &initial_entries;
    var documents: Documents = &initial_documents;

    var stores = struct {
        store_0: *Entries,
        store_1: *Documents,
        pub fn commit(self: *@This(), pending: workflow.zx_pending) error{}!void {
            if (pending.store_0) |next| self.store_0.* = next;
            if (pending.store_1) |next| self.store_1.* = next;
        }
    }{ .store_0 = &collected, .store_1 = &documents };

    const result = workflow.executeIn(scratch, &input, &stores, io) catch |err| return failure orelse err;

    if (result.failure) |code| return @errorFromInt(code);

    return result.text.?;
}

const Error = error{GenerationRequestFailed};

const PreparedModules = struct {
    rows: []const @import("rx").ModuleSource,
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

        for (inputs.modules, digests) |module, *item| {
            item.* = .{ .path = module.path, .digest = resident.files.digest(module.path, module.source) };
        }

        const frame = fingerprint.seedFrame(&resident.digest, self.manifest_source, digests, bindings);

        return .{
            .frame = frame,
            .modules = digests,
            .output = fingerprint.seedOutput(&frame.content, self.request.partitions, inputs.sources, inputs.templates, &resident.files),
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

    fn prepareTemplates(self: *const GenerationIO, sources: []const compiler.project.Source) ![]const compiler.project.Source {
        return switch (try compiler.project.prepareSources(self.owned, sources, .{ .entry = "" })) {
            .sources => |items| items,
            .diagnostic => |issue| {
                std.debug.print("{s}: {s}\n", .{ sources[issue.source_index.?].path, issue.message });

                return error.InvalidTemplateResource;
            },
        };
    }

    fn prepareModules(self: *const GenerationIO, modules: []const @import("rx").TextSource, packages: []const compiler.project.Package) ![]const @import("rx").ModuleSource {
        return self.resident.modules.prepare(self.owned, modules, try fingerprint.packages(self.allocator, packages));
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

            std.Io.Dir.cwd().deleteFile(io, stamp_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }

        const previous = if (interfaces.failure == null) self.resident.exactAnalysis(&digests.output) else null;

        const summary = if (previous) |saved| try generation.restore(self.target(io), saved, self.project.entries.len) else fresh: {
            const sources = try self.prepareTemplates(inputs.sources);
            const modules = try self.prepareModules(inputs.modules, packages);

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

fn generationRoots(allocator: std.mem.Allocator, project: []const manifest.Root) ![]const Host.GenerationRoot {
    const rows = try allocator.alloc(std.meta.Child(Host.GenerationRoot), project.len);
    const result = try allocator.alloc(Host.GenerationRoot, project.len);

    for (project, rows, result) |root, *row, *value| {
        row.* = .{ .path = root.path, .prefix = root.prefix };
        value.* = row;
    }

    return result;
}

fn generationInterfaces(allocator: std.mem.Allocator, project: []const manifest.Interface) ![]const Host.GenerationInterface {
    const rows = try allocator.alloc(std.meta.Child(Host.GenerationInterface), project.len);
    const result = try allocator.alloc(Host.GenerationInterface, project.len);

    for (project, rows, result) |decl, *row, *value| {
        row.* = .{
            .specifier = decl.specifier,
            .path = decl.path,
            .module = decl.module,
            .resolve_members = decl.resolve_members orelse false,
        };

        value.* = row;
    }

    return result;
}

fn listedMetadata(value: Host.GenerationPath) ?Files.Metadata {
    const modified = value.mtime_ns orelse return null;
    const changed = value.ctime_ns orelse return null;

    return .{
        .inode = value.inode orelse return null,
        .size = value.size orelse return null,
        .mtime = nanoseconds(modified),
        .ctime = nanoseconds(changed),
    };
}

fn nanoseconds(time: Host.GenerationTime) i96 {
    return (@as(i96, time.high) << 64) | time.low;
}

pub fn readGenerationFiles(allocator: std.mem.Allocator, io: std.Io, reference: *const anyopaque, input: Host.GenerationRead) Error!Host.GenerationReadResult {
    const host = borrow(GenerationIO, reference);

    return readFiles(host, allocator, io, input) catch |err| host.fail(err);
}

fn readFiles(host: *const GenerationIO, allocator: std.mem.Allocator, io: std.Io, input: Host.GenerationRead) !Host.GenerationReadResult {
    const directory = if (input.root) |root| try std.Io.Dir.cwd().openDir(io, root, .{}) else std.Io.Dir.cwd();

    defer if (input.root != null) directory.close(io);

    const fields = try allocator.alloc(std.meta.Child(Host.GenerationDocument), input.files.len);
    const documents = try allocator.alloc(Host.GenerationDocument, input.files.len);
    const digests = try allocator.alloc(fingerprint.Digest, if (input.root != null) input.files.len else 0);
    const versions = try allocator.alloc(std.meta.Child(Host.GenerationVersion), if (host.request.write) input.files.len else 0);
    const files = &host.resident.files;
    var failure: ?u16 = null;

    for (input.files, fields, documents, 0..) |item, *field, *document, row| {
        const key = if (input.root != null) item.path else try std.fs.path.resolve(allocator, &.{item.path});

        const read = files.readObserved(io, directory, item.relative, key, item.retain, listedMetadata(item)) catch |err| read: {
            if (!input.optional) return err;
            if (failure == null) failure = @intFromError(err);

            break :read null;
        };

        const source = if (read) |value| value.text else "";
        const path = if (read) |value| value.key else key;

        const digest: []const u8 = if (input.root != null) digest: {
            digests[row] = files.digest(key, source);

            break :digest &digests[row];
        } else &.{};

        const version = if (host.request.write and read != null) observedVersion(read.?.version, &versions[row]) else null;

        field.* = .{ .path = path, .source = source, .digest = digest, .version = version };
        document.* = field;
    }

    return keep(host, allocator, @as(std.meta.Child(Host.GenerationReadResult), .{ .documents = documents, .failure = failure }));
}

fn observedVersion(version: Files.Version, output: *std.meta.Child(Host.GenerationVersion)) Host.GenerationVersion {
    const timestamp = compiler.input_snapshot.timestamp;
    const modified = timestamp(version.metadata.mtime);
    const changed = timestamp(version.metadata.ctime);
    const read = timestamp(version.read);

    output.* = .{
        .inode = version.metadata.inode,
        .size = version.metadata.size,
        .mtime_low = modified.low,
        .ctime_low = changed.low,
        .read_low = read.low,
        .mtime_high = modified.high,
        .ctime_high = changed.high,
        .read_high = read.high,
    };

    return output;
}

pub fn restoreGenerationAnalysis(io: std.Io, reference: *const anyopaque, digest: []const u8) Error!?[]const u8 {
    const host = borrow(GenerationIO, reference);
    const saved = host.resident.exactAnalysis(digest[0..@sizeOf(fingerprint.Digest)]) orelse return null;

    return generation.restore(host.target(io), saved, host.project.entries.len) catch |err| host.fail(err);
}

pub fn prepareGenerationTemplates(allocator: std.mem.Allocator, reference: *const anyopaque, catalog: Host.GenerationCatalog) Error!Host.GenerationArtifact {
    const host = borrow(GenerationIO, reference);
    const templates = host.owned.alloc(compiler.project.Resource, catalog.templates.len) catch |err| return host.fail(err);
    const input = host.owned.alloc(compiler.project.Source, catalog.sources.len) catch |err| return host.fail(err);

    for (templates, catalog.templates) |*slot, doc| slot.* = .{ .path = doc.path, .source = doc.source };
    for (input, catalog.sources) |*slot, doc| slot.* = .{ .path = doc.path, .source = doc.source, .templates = templates };

    const sources = host.prepareTemplates(input) catch |err| return host.fail(err);

    return @ptrCast(try keep(host, allocator, sources));
}

pub fn prepareGenerationModules(allocator: std.mem.Allocator, reference: *const anyopaque, catalog: Host.GenerationCatalog) Error!Host.GenerationArtifact {
    const host = borrow(GenerationIO, reference);
    const packages = host.retainPackages(catalog.packages) catch |err| return host.fail(err);
    const input = host.owned.alloc(@import("rx").TextSource, catalog.modules.len) catch |err| return host.fail(err);

    for (input, catalog.modules) |*slot, doc| slot.* = .{ .path = doc.path, .source = doc.source, .packages = packages };

    const rows = host.prepareModules(input, packages) catch |err| return host.fail(err);

    return @ptrCast(try keep(host, allocator, PreparedModules{ .rows = rows, .packages = packages }));
}

pub fn generateFromPreparedInputs(io: std.Io, reference: *const anyopaque, digests: Host.PreparedGeneration, interfaces: Host.GenerationRegistration, sources: *const anyopaque, modules: *const anyopaque) Error![]const u8 {
    const host = borrow(GenerationIO, reference);
    const ready = materializeDigests(host.owned, digests) catch |err| return host.fail(err);
    const bindings = materializeInterfaces(host, interfaces) catch |err| return host.fail(err);
    const source_rows = borrow([]const compiler.project.Source, sources);
    const prepared = borrow(PreparedModules, modules);

    return host.emit(io, ready, prepared.packages, bindings, source_rows.*, prepared.rows) catch |err| host.fail(err);
}

fn materializeInterfaces(host: *const GenerationIO, typed: Host.GenerationRegistration) !interface_inputs.Result {
    const bindings = try host.owned.alloc(compiler.project.NativeInterface, typed.bindings.len);

    for (bindings, typed.bindings, 0..) |*slot, binding, row| {
        slot.* = .{
            .specifier = if (row < typed.external) try host.resident.retainText(host.owned, binding.name) else try host.owned.dupe(u8, binding.name),
            .path = try host.resident.retainText(host.owned, binding.path),
            .source = binding.source,
            .namespace = if (binding.resolve_members) &.{compiler.native_lookup.marker} else &.{},
            .module = try host.resident.retainText(host.owned, binding.module),
        };
    }

    return .{ .bindings = bindings, .external = @intCast(typed.external), .failure = null };
}

fn materializeDigests(allocator: std.mem.Allocator, typed: Host.PreparedGeneration) !Digests {
    const modules = try allocator.alloc(analysis.project.ModuleDigest, typed.digests.len);
    const width = @sizeOf(fingerprint.Digest);

    for (modules, typed.digests) |*module, row| module.* = .{ .path = row.path, .digest = row.digest[0..width].* };

    return .{
        .frame = .{ .content = typed.content[0..width].*, .shape = typed.shape[0..width].* },
        .modules = modules,
        .output = typed.digest[0..width].*,
    };
}

fn borrow(comptime T: type, reference: *const anyopaque) *const T {
    return @ptrCast(@alignCast(reference));
}

fn keep(host: *const GenerationIO, allocator: std.mem.Allocator, value: anytype) Error!*const @TypeOf(value) {
    const slot = allocator.create(@TypeOf(value)) catch |err| return host.fail(err);

    slot.* = value;

    return slot;
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

fn writeGenerationStamp(io: std.Io, path: []const u8, stamp: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = stamp });
}
