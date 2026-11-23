const std = @import("std");
const zx = @import("zx");
const Analysis = @import("../../analysis/analyze.zig");
const Cache = @import("../semantic_cache.zig");
const extract = @import("../artifact/extract.zig").validated;

pub const Context = struct {
    root: [32]u8 = undefined,
    dependency: [32]u8 = undefined,
    dependency_ready: bool = false,
    pub fn compute(self: *Context, allocator: std.mem.Allocator, root: ?Analysis.Context) std.mem.Allocator.Error!*const [32]u8 {
        if (root) |context| {
            self.root = try Cache.contextDigest(allocator, context);

            return &self.root;
        }

        self.dependency = try Cache.contextDigest(allocator, .{});
        self.dependency_ready = true;

        return &self.dependency;
    }
};

pub const Status = enum { Stored, MissingOrigin, Invalid };

pub const invalid: zx.Diagnostic = .{
    .code = .contract,
    .span = .{ .start = 0, .end = 0 },
    .message = "module artifact extraction requires valid project IR and module metadata",
};

pub fn storeSeed(cache: *Cache, scratch: *zx.Arena, result: *const Analysis.Result, index: usize, root: bool, context: *const Context) std.mem.Allocator.Error!Status {
    defer scratch.reset(std.math.maxInt(usize));

    var artifact = extract(cache.allocator, scratch.allocator(), result, result.modules[index]) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.MissingNominalOrigin => .MissingOrigin,
        error.InvalidAnalysis, error.InvalidModule, error.InvalidIr => .Invalid,
    };

    errdefer artifact.deinit();

    const digest = if (root) &context.root else &context.dependency;

    try cache.put(artifact, digest.*);

    return .Stored;
}
