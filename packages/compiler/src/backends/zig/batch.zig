const std = @import("std");
const ir = @import("zx").ir;
const genz = @import("genz");
const generating = genz.zx.modules;
const fingerprint = @import("fingerprint.zig");
const Cache = @import("cache.zig");
const Self = @This();

backing: std.mem.Allocator,
program: ir.Program,
names: generating.Names,
analysis: generating.Analysis.Owned,
cache: ?*Cache,
public_members: []const generating.PublicMember = &.{},
pub fn create(backing: std.mem.Allocator, program: ir.Program, names: generating.Names, cache: ?*Cache) std.mem.Allocator.Error!Self {
    return createExported(backing, program, names, cache, &.{});
}

/// A batch whose `exported` functions the host also calls directly.
pub fn createExported(backing: std.mem.Allocator, program: ir.Program, names: generating.Names, cache: ?*Cache, exported: []const ir.FunctionId) std.mem.Allocator.Error!Self {
    return createRemembered(backing, program, names, cache, exported, null);
}

/// A batch whose uniqueness analysis also reuses and extends the body analyses `memo` remembers.
pub fn createRemembered(backing: std.mem.Allocator, program: ir.Program, names: generating.Names, cache: ?*Cache, exported: []const ir.FunctionId, memo: ?*generating.Analysis.Uniqueness.Memo) std.mem.Allocator.Error!Self {
    return .{ .backing = backing, .program = program, .names = names, .analysis = try generating.Analysis.createRemembered(backing, program, exported, memo), .cache = cache };
}

/// A batch over facts already computed for `program`, which it takes ownership of.
pub fn fromAnalysis(backing: std.mem.Allocator, program: ir.Program, names: generating.Names, cache: ?*Cache, analysis: generating.Analysis.Owned) Self {
    return .{ .backing = backing, .program = program, .names = names, .analysis = analysis, .cache = cache };
}

pub fn deinit(self: *Self) void {
    self.analysis.deinit();

    self.* = undefined;
}

pub const Lookup = struct { name: []const u8, key: [32]u8, source: ?[]const u8 };

pub fn emit(self: *const Self, owned: std.mem.Allocator, unit: generating.Unit) generating.Error![]const u8 {
    if (self.cache == null) return self.generate(owned, self.backing, unit, null);

    var scratch = std.heap.ArenaAllocator.init(self.backing);

    defer scratch.deinit();

    const found = try self.lookup(scratch.allocator(), unit);

    if (found.source) |source| return owned.dupe(u8, source);

    const source = try self.generate(owned, self.backing, unit, null);

    errdefer owned.free(source);

    try self.remember(found, source);

    return source;
}

/// Cache identity and cached source of one unit; names and keys live in `scratch`.
pub fn lookup(self: *const Self, scratch: std.mem.Allocator, unit: generating.Unit) generating.Error!Lookup {
    var found = try self.identify(scratch, unit);
    found.source = if (self.cache) |store| try store.get(found.name, found.key) else null;

    return found;
}

/// The cache name and key of a unit; pure, so threads may identify units of one batch together.
pub fn identify(self: *const Self, scratch: std.mem.Allocator, unit: generating.Unit) generating.Error!Lookup {
    const name = switch (unit) {
        .function => |id| self.names.functions[@backingInt(id)],
        // Kept beside the value-only file, so a run that needs both finds each one cached.
        .regular => |id| try std.fmt.allocPrint(scratch, "{s}:call", .{self.names.functions[@backingInt(id)]}),
        .entry, .types => try std.fmt.allocPrint(scratch, "{s}:{s}", .{ @tagName(unit), self.program.file_name }),
    };

    var key = fingerprint.createAnalyzed(self.program, self.names, unit, self.analysis.value);

    if (unit == .entry and self.public_members.len != 0) {
        const Hash = @import("zx").Sha256;

        if (comptime @import("parser_options").generated_parser) {
            var buffer: [512]u8 = undefined;
            var hash: std.Io.Writer.Hashing(Hash) = .init(&buffer);

            @import("fingerprint/source.zig").members(&hash.writer, &key, self.public_members, self.names.functions);
            hash.writer.flush() catch unreachable;
            hash.hasher.final(&key);

            return .{ .name = name, .key = key, .source = null };
        }

        var hash = Hash.init(.{});

        hash.update(&key);

        for (self.public_members) |member| {
            const target = self.names.functions[@backingInt(member.function)];

            hash.update(std.mem.asBytes(&member.name.len));
            hash.update(member.name);
            hash.update(std.mem.asBytes(&target.len));
            hash.update(target);
        }

        hash.final(&key);
    }

    return .{ .name = name, .key = key, .source = null };
}

/// Pure generation of one unit; threads may share a batch when each passes its own `owned` and a thread-safe `backing`.
pub fn generate(self: *const Self, owned: std.mem.Allocator, backing: std.mem.Allocator, unit: generating.Unit, scratch: ?*generating.TypeScratch) generating.Error![]const u8 {
    if (unit == .entry and self.public_members.len != 0) return generating.publicEntry(owned, backing, self.program, self.names, self.analysis.value, self.public_members);

    return generating.analyzedWithScratch(owned, backing, self.program, self.names, unit, self.analysis.value, scratch);
}

pub fn remember(self: *const Self, found: Lookup, source: []const u8) std.mem.Allocator.Error!void {
    const store = self.cache orelse return;

    store.generated += 1;

    try store.put(found.name, found.key, source);
}
