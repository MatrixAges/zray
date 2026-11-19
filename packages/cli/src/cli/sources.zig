const std = @import("std");
const compiler = @import("compiler");
const zx = @import("zx");
const Inputs = @import("watch/inputs.zig");
const Libraries = @import("library/inputs.zig");

pub fn read(io: std.Io, allocator: std.mem.Allocator, source: []const u8, project: compiler.project.Options, cache: *compiler.project.ParseCache) ![]const compiler.project.Source {
    return readWithInputs(io, allocator, source, project, cache, null);
}

pub fn readWithInputs(io: std.Io, allocator: std.mem.Allocator, source: []const u8, project: compiler.project.Options, cache: *compiler.project.ParseCache, inputs: ?*Inputs) ![]const compiler.project.Source {
    return readWithLibraries(io, allocator, source, project, cache, inputs, null);
}

pub fn readWithLibraries(io: std.Io, allocator: std.mem.Allocator, source: []const u8, project: compiler.project.Options, cache: *compiler.project.ParseCache, inputs: ?*Inputs, libraries: ?*Libraries) ![]const compiler.project.Source {
    return readInternal(io, allocator, source, project, cache, inputs, libraries, null);
}

pub const Detected = struct { sources: []const compiler.project.Source, has_rx: bool };

pub fn readDetectingRx(io: std.Io, allocator: std.mem.Allocator, source: []const u8, project: compiler.project.Options, cache: *compiler.project.ParseCache, inputs: ?*Inputs, libraries: ?*Libraries) !Detected {
    var has_rx = false;
    const sources = try readInternal(io, allocator, source, project, cache, inputs, libraries, &has_rx);

    return .{ .sources = sources, .has_rx = has_rx };
}

pub const Known = std.StringHashMapUnmanaged([]const u8);

pub const Traversal = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    project: compiler.project.Options,
    cache: *compiler.project.ParseCache,
    inputs: ?*Inputs,
    libraries: ?*Libraries,
    has_rx: ?*bool = null,
    /// Preloaded text has the same lifetime as the resulting source list.
    known: ?*const Known = null,
    sources: std.ArrayList(compiler.project.Source) = .empty,
    paths: std.StringHashMapUnmanaged(void) = .empty,
    pub fn deinit(self: *Traversal) void {
        self.paths.deinit(self.allocator);
        self.sources.deinit(self.allocator);
    }
    pub fn readEntry(self: *Traversal, path: []const u8, source: []const u8) !void {
        const allocator = self.allocator;
        var project = self.project;

        project.entry = path;

        if (self.inputs) |observed| try observed.add(self.io, path);
        try @import("../package/source.zig").validateWithInputs(self.io, allocator, path, project.package_scopes, self.inputs);
        if (self.inputs) |observed| try observed.record(self.io, path, source);

        var index = self.sources.items.len;

        try self.append(.{ .path = path, .source = source });

        while (index < self.sources.items.len) : (index += 1) {
            const item = try @import("sources/templates.zig").prepare(self.io, allocator, self.sources.items[index], project, self.inputs);

            self.sources.items[index] = item;

            const canonical_path = try std.fs.path.resolve(allocator, &.{ project.root_dir, item.path });

            defer allocator.free(canonical_path);

            const parsed = try self.cache.getModule(item.source, canonical_path);

            if (parsed.diagnostic() != null) continue;

            switch (parsed.*) {
                .native => |result| try self.readImports(zx.syntax.header.Native{ .program = result.value.parsed.ast }, canonical_path, project),
                .indexed => |*result| if (compiler.project.ParseCache.indexed_enabled) try self.readImports(result.header(), canonical_path, project) else unreachable,
            }
        }
    }

    fn append(self: *Traversal, source: compiler.project.Source) !void {
        try self.sources.ensureUnusedCapacity(self.allocator, 1);
        try self.paths.put(self.allocator, source.path, {});

        self.sources.appendAssumeCapacity(source);
    }
    fn readImports(self: *Traversal, header: anytype, owner: []const u8, project: compiler.project.Options) !void {
        for (0..header.importCount()) |index| {
            const imported = header.importAt(index);
            var reporter: zx.Reporter = .{};

            const reference = compiler.project.resolveModuleReference(self.allocator, owner, imported.path, project, &reporter, imported.span) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;

                continue;
            };

            const candidate = switch (reference.target) {
                .source => |path| path,
                .compiled => |compiled| {
                    const collection = self.libraries orelse return error.CompiledLibraryLoaderRequired;

                    try collection.add(self.io, compiled, project, self.inputs);

                    continue;
                },
            };

            if (std.mem.endsWith(u8, candidate, ".rx")) {
                if (self.has_rx) |found| found.* = true;

                continue;
            }

            const path = if (reference.file) try @import("sources/module_path.zig").select(self.io, self.allocator, candidate, self.inputs) else candidate;

            if (reference.file) compiler.project.checkFileTarget(owner, path, project, &reporter, imported.span) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;

                continue;
            };

            if (self.paths.contains(path)) continue;
            if (self.inputs) |observed| try observed.add(self.io, path);

            @import("../package/source.zig").validateWithInputs(self.io, self.allocator, path, project.package_scopes, self.inputs) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };

            const known_text = if (self.known) |known| known.get(path) else null;

            const text = known_text orelse std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };

            if (self.inputs) |observed| try observed.record(self.io, path, text);
            try self.append(.{ .path = path, .source = text });
        }
    }
};

fn readInternal(io: std.Io, allocator: std.mem.Allocator, source: []const u8, project: compiler.project.Options, cache: *compiler.project.ParseCache, inputs: ?*Inputs, libraries: ?*Libraries, has_rx: ?*bool) ![]const compiler.project.Source {
    var traversal: Traversal = .{ .io = io, .allocator = allocator, .project = project, .cache = cache, .inputs = inputs, .libraries = libraries, .has_rx = has_rx };

    defer traversal.deinit();

    try traversal.readEntry(project.entry, source);

    return traversal.sources.toOwnedSlice(allocator);
}
