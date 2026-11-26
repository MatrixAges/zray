const std = @import("std");
const zx = @import("zx");
const generating = @import("genz").zx.state;
const modules = @import("../modules.zig");
const Cache = @import("../cache.zig");
const Error = std.mem.Allocator.Error;
const Self = @This();

bundle: *modules.Bundle,
temporary: std.mem.Allocator,
imports: []const []const u8,
writable: []const bool,
independent: bool,
requirements: generating.Requirements,
cache: ?*Cache,
pub fn run(self: *Self) Error!void {
    const name = @import("generated_state_constants").@"zx.constants".state_name;

    const source = if (self.cache) |cache| blk: {
        var buffer: [512]u8 = undefined;
        var hash: std.Io.Writer.Hashing(zx.Sha256) = .init(&buffer);
        var key: [32]u8 = undefined;
        const fingerprint = @import("generated_state_publication_fingerprint");

        const input: std.meta.Child(fingerprint.Input) = .{
            .writer = @ptrCast(&hash.writer),
            .imports = self.imports,
            .writable = self.writable,
            .independent = self.independent,
            .io = self.requirements.io,
            .process = self.requirements.process,
        };

        fingerprint.executeIn(self.temporary, &input) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
            else => unreachable,
        };

        hash.writer.flush() catch unreachable;
        hash.hasher.final(&key);

        if (try cache.get(name, key)) |cached| break :blk try self.bundle.arena.allocator().dupe(u8, cached);

        const rendered = try self.render();

        cache.generated += 1;

        try cache.put(name, key, rendered);

        break :blk rendered;
    } else try self.render();

    const old = self.bundle.modules;
    const files = try self.bundle.arena.allocator().alloc(modules.File, old.len + 1);

    @memcpy(files[0..old.len], old);

    files[old.len] = .{ .name = name, .source = source, .imports = self.imports };
    self.bundle.modules = files;
    self.bundle.state_module = name;
}

fn render(self: *const Self) Error![]const u8 {
    const allocator = self.bundle.arena.allocator();
    const names = self.imports[1..];

    if (comptime generating.generated) {
        const columns = generating.ObjectColumns.fromBindings(names, self.writable, self.independent);

        return generating.renderColumns(allocator, columns, self.requirements, true);
    }

    const objects = try @import("objects.zig").create(self.temporary, names, self.writable, self.independent);

    return generating.renderWithCapabilities(allocator, objects, self.requirements);
}
