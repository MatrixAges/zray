const std = @import("std");
const compiler = @import("compiler");
const Inputs = @import("watch_inputs").Inputs;
const Libraries = @import("library/inputs.zig");
const Text = @import("sources/text.zig");
const Discovery = @import("sources/discovery/host.zig");

pub fn read(io: std.Io, allocator: std.mem.Allocator, source: []const u8, project: compiler.project.Options, cache: *compiler.project.ParseCache) ![]const compiler.project.Source {
    return readWithInputs(io, allocator, source, project, cache, null);
}

pub fn readWithInputs(io: std.Io, allocator: std.mem.Allocator, source: []const u8, project: compiler.project.Options, cache: *compiler.project.ParseCache, inputs: ?*Inputs) ![]const compiler.project.Source {
    return readWithLibraries(io, allocator, source, project, cache, inputs, null);
}

pub fn readWithLibraries(io: std.Io, allocator: std.mem.Allocator, source: []const u8, project: compiler.project.Options, cache: *compiler.project.ParseCache, inputs: ?*Inputs, libraries: ?*Libraries) ![]const compiler.project.Source {
    var traversal: Traversal = .{ .io = io, .allocator = allocator, .project = project, .cache = cache, .inputs = inputs, .libraries = libraries };

    return readInternal(&traversal, source, false);
}

pub const Detected = struct { sources: []const compiler.project.Source, has_rx: bool };

pub fn readDetectingRx(io: std.Io, allocator: std.mem.Allocator, source: []const u8, project: compiler.project.Options, cache: *compiler.project.ParseCache, inputs: ?*Inputs, libraries: ?*Libraries) !Detected {
    var traversal: Traversal = .{ .io = io, .allocator = allocator, .project = project, .cache = cache, .inputs = inputs, .libraries = libraries };

    return detect(&traversal, source, false);
}

pub fn readLibrary(io: std.Io, allocator: std.mem.Allocator, project: compiler.project.Options, cache: *compiler.project.ParseCache, inputs: ?*Inputs, libraries: *Libraries, texts: *Text.Cache) !Detected {
    const source = try Text.read(io, allocator, project.entry, texts);
    var traversal: Traversal = .{ .io = io, .allocator = allocator, .project = project, .cache = cache, .inputs = inputs, .libraries = libraries, .texts = texts };

    return detect(&traversal, source.bytes, !source.fresh);
}

fn detect(traversal: *Traversal, source: []const u8, recorded: bool) !Detected {
    var has_rx = false;
    traversal.has_rx = &has_rx;

    const sources = try readInternal(traversal, source, recorded);

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
    texts: ?*Text.Cache = null,
    sources: std.ArrayList(compiler.project.Source) = .empty,
    paths: std.StringHashMapUnmanaged(void) = .empty,
    pub fn deinit(self: *Traversal) void {
        self.paths.deinit(self.allocator);
        self.sources.deinit(self.allocator);
    }
    pub fn readEntry(self: *Traversal, path: []const u8, source: []const u8, recorded: bool) !void {
        try Discovery.run(self, path, source, recorded);
    }

    pub fn append(self: *Traversal, source: compiler.project.Source) !void {
        try self.sources.ensureUnusedCapacity(self.allocator, 1);
        try self.paths.put(self.allocator, source.path, {});

        self.sources.appendAssumeCapacity(source);
    }
};

fn readInternal(traversal: *Traversal, source: []const u8, recorded: bool) ![]const compiler.project.Source {
    defer traversal.deinit();

    try traversal.readEntry(traversal.project.entry, source, recorded);

    return traversal.sources.toOwnedSlice(traversal.allocator);
}
