//! The RX modules a resident generator parsed last, kept while every path and text stays the same: parsing and
//! validating them takes longer than the rest of the setup of a build that changed none. A replaced parse stays alive
//! until `release`, since analyses may point into its nodes.
const std = @import("std");
const rx = @import("rx");
const compiler = @import("compiler");
const inputs = compiler.parsed_inputs;
const Self = @This();

gpa: std.mem.Allocator,
current: ?rx.TextResult = null,
packages: [32]u8 = undefined,
/// The paths and texts `current` was parsed from, in turn.
comparison: ?inputs.Columns = null,
replaced: std.ArrayList(rx.TextResult) = .empty,
pub fn deinit(self: *Self) void {
    self.release();
    self.replaced.deinit(self.gpa);
    if (self.current) |*parsed| parsed.deinit();
}

/// The parse of `sources`; the kept one while their paths and texts match it.
pub fn parse(self: *Self, sources: []const rx.TextSource, packages: [32]u8) !*const rx.TextResult {
    if (self.comparison) |previous| {
        if (compiler.bytes.equal(&self.packages, &packages) and inputs.same(previous, sources)) return &self.current.?;
    }

    var parsed = try rx.parseModules(self.gpa, sources);

    errdefer parsed.deinit();

    if (self.current != null) try self.replaced.ensureUnusedCapacity(self.gpa, 1);

    const comparison = try retainInputs(&parsed, sources);

    if (self.current) |old| self.replaced.appendAssumeCapacity(old);

    self.comparison = comparison;
    self.current = parsed;
    self.packages = packages;

    return &self.current.?;
}

/// Frees the parses replaced since the last call.
pub fn release(self: *Self) void {
    for (self.replaced.items) |*parsed| parsed.deinit();

    self.replaced.clearRetainingCapacity();
}

fn retainInputs(parsed: *rx.TextResult, sources: []const rx.TextSource) !inputs.Columns {
    const owned = parsed.arena.allocator();
    const paths = try owned.alloc([]const u8, sources.len);
    const texts = try owned.alloc([]const u8, sources.len);

    for (sources, paths, texts, 0..) |source, *path, *text, index| {
        path.* = try owned.dupe(u8, source.path);
        text.* = if (parsed.value == .data) parsed.parsed[index].source else try owned.dupe(u8, source.source);
    }

    return .{ .paths = paths, .texts = texts };
}
