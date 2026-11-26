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

    return (try readInternal(&traversal, source, false)).sources;
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
    return readInternal(traversal, source, recorded);
}

pub const Known = std.StringHashMapUnmanaged([]const u8);

pub const Traversal = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    project: compiler.project.Options,
    cache: *compiler.project.ParseCache,
    inputs: ?*Inputs,
    libraries: ?*Libraries,
    /// Preloaded text has the same lifetime as the resulting source list.
    known: ?*const Known = null,
    texts: ?*Text.Cache = null,
    sources: std.ArrayList(compiler.project.Source) = .empty,
    seen_arena: ?std.heap.ArenaAllocator = null,
    seen_paths: []const []const u8 = &.{},
    pub fn deinit(self: *Traversal) void {
        if (self.seen_arena) |*arena| arena.deinit();

        self.sources.deinit(self.allocator);
    }

    pub fn hasSeen(self: *const Traversal, path: []const u8) bool {
        for (self.seen_paths) |seen| {
            if (std.mem.eql(u8, seen, path)) return true;
        }

        return false;
    }

    pub fn readEntry(self: *Traversal, path: []const u8, source: []const u8, recorded: bool) !bool {
        return Discovery.run(self, path, source, recorded);
    }

    pub fn append(self: *Traversal, source: compiler.project.Source) !void {
        try self.sources.append(self.allocator, source);
    }
};

fn readInternal(traversal: *Traversal, source: []const u8, recorded: bool) !Detected {
    defer traversal.deinit();

    const has_rx = try traversal.readEntry(traversal.project.entry, source, recorded);

    return .{ .sources = try traversal.sources.toOwnedSlice(traversal.allocator), .has_rx = has_rx };
}
