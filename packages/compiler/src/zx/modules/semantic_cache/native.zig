const std = @import("std");
const zx = @import("zx");
const Native = @import("../interface.zig").Native;
const Loaded = @import("../native.zig");
const restoring = @import("native_restore.zig");
const entries = @import("entries.zig");
const Self = @This();
pub const Current = restoring.Current;
pub const empty_context: [32]u8 = @splat(0);

allocator: std.mem.Allocator,
items: entries.Map = .empty,
analyzed: usize = 0,
reused: usize = 0,
pub fn deinit(self: *Self) void {
    entries.deinit(self.allocator, &self.items);

    self.* = undefined;
}

const Request = struct {
    cache: *Self,
    allocator: std.mem.Allocator,
    native: *const Native,
    current: Current,
    reporter: *zx.Reporter,
    span: zx.Span,
    fingerprint: [32]u8,
    slot: entries.Pending,
    result: Loaded.Result = undefined,
    fn borrow(handle: *anyopaque) *Request {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn load(self: *Self, allocator: std.mem.Allocator, entry: Native, current: Current, reporter: *zx.Reporter, span: zx.Span) zx.Error!Loaded.Result {
    var request: Request = .{
        .cache = self,
        .allocator = allocator,
        .native = &entry,
        .current = current,
        .reporter = reporter,
        .span = span,
        .fingerprint = try digest(allocator, entry),
        .slot = .{ .allocator = self.allocator, .entries = &self.items },
    };

    errdefer if (request.slot.value) |*value| value.result.deinit();
    errdefer request.slot.cancel();

    if (comptime @import("parser_options").generated_parser) {
        const generated = @import("generated_semantic_cache_load_native");
        const usage: zx.memory.ColumnLengths = &.{ &self.analyzed, &self.reused };
        const Input = std.meta.Child(generated.Input);
        const Lookup = std.meta.Child(@FieldType(Input, "lookup"));
        const Candidate = std.meta.Child(@FieldType(Lookup, "candidate"));
        const cached = self.items.get(entry.key());
        const candidate = if (cached) |stored| stored.digestView(std.meta.Child(Candidate)) else null;

        const input: Input = .{
            .frame = @ptrCast(&request),
            .slot = @ptrCast(&request.slot),
            .lookup = &.{
                .candidate = if (candidate) |*value| value else null,
                .source = &request.fingerprint,
                .context = &empty_context,
            },
            .usage = @ptrCast(&usage),
        };

        var arena = std.heap.ArenaAllocator.init(current.backing);

        defer arena.deinit();

        var buffer: [256]u8 = undefined;
        var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());
        const outcome = generated.executeIn(scratch.allocator(), &input) catch |err| return @import("../project/execution/invoke.zig").errorSet(err);

        if (outcome.pending) |prepared| entries.commitPrepared(&request.slot, prepared);
        if (outcome.admitted) cached.?.native_admitted = true;
    } else {
        try seed(&request);
    }

    return request.result;
}

fn seed(request: *Request) zx.Error!void {
    if (entries.find(&request.cache.items, request.native.key(), &request.fingerprint, &empty_context)) |cached| {
        if (try restoreCachedNative(request, cached)) {
            cached.native_admitted = true;
            request.cache.reused += 1;

            return;
        }
    }

    request.cache.analyzed += 1;

    try buildNativeCacheEntry(request);

    const position = try entries.prepareSeed(&request.slot);

    try validateNativeCacheEntry(request);

    entries.commitSeed(&request.slot, position);
}

pub fn restoreCachedNative(handle: *anyopaque, candidate: *anyopaque) std.mem.Allocator.Error!bool {
    const request = Request.borrow(handle);
    const entry = request.native.*;
    const cached: *const entries.Entry = @ptrCast(@alignCast(candidate));

    request.result = restoring.restore(request.allocator, &cached.result.value, entry, request.current, cached.native_admitted) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };

    return true;
}

pub fn buildNativeCacheEntry(handle: *anyopaque) zx.Error!void {
    const request = Request.borrow(handle);
    const artifact = try @import("native_artifact.zig").create(request.cache.allocator, request.native.*, request.fingerprint, request.allocator, request.reporter, request.span);

    request.slot.value = .{
        .result = artifact,
        .context_digest = empty_context,
        .native_admitted = true,
    };
}

pub fn validateNativeCacheEntry(handle: *anyopaque) zx.Error!void {
    const request = Request.borrow(handle);
    const artifact = &request.slot.value.?.result.value;

    request.result = restoring.restore(request.allocator, artifact, request.native.*, request.current, false) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidIr => return request.reporter.fail(.module, request.span, "native declarations produced invalid interface IR"),
        else => return request.reporter.fail(.module, request.span, "native interface artifact could not be mapped into the project"),
    };
}

fn digest(allocator: std.mem.Allocator, entry: Native) std.mem.Allocator.Error![32]u8 {
    const fields = [_][]const u8{ entry.key(), entry.specifier, entry.path, entry.source, entry.module };

    if (comptime @import("parser_options").generated_parser) {
        const generated = @import("generated_semantic_cache_native_fingerprint");
        var buffer: [2048]u8 = undefined;
        var backing = std.heap.BufferFirstAllocator.init(&buffer, allocator);
        var arena = std.heap.ArenaAllocator.init(backing.allocator());

        defer arena.deinit();

        const input: std.meta.Child(generated.Input) = .{ .fields = &fields, .namespace = entry.namespace };

        const result = generated.executeIn(arena.allocator(), &input) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };

        std.debug.assert(result.len == 32);

        return result[0..32].*;
    }

    var hash = zx.Sha256.init(.{});

    field(&hash, "zxc.native.interface.v2");

    for (fields) |part| field(&hash, part);
    for (entry.namespace) |part| field(&hash, part);

    var result: [32]u8 = undefined;

    hash.final(&result);

    return result;
}

fn field(hash: *@import("zx").Sha256, bytes: []const u8) void {
    var length: [8]u8 = undefined;

    std.mem.writeInt(u64, &length, @intCast(bytes.len), .little);
    hash.update(&length);
    hash.update(bytes);
}
