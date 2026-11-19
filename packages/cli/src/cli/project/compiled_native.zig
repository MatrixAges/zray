const std = @import("std");
const compiler = @import("compiler");
const model = @import("../../package/manifest/model.zig");
const Inputs = @import("../watch/inputs.zig");
const identity = compiler.project.compiled.identity;
const admission = @import("cli_source").compiled_native_artifact;
const Self = @This();

library: compiler.library.Result,
instance: []const u8,
pub fn load(io: std.Io, allocator: std.mem.Allocator, root: []const u8, config: model.Manifest, scopes: []const compiler.project.PackageScope, inputs: ?*Inputs) !?Self {
    const Input = std.meta.Child(admission.Input);
    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    const relative = (@import("zx").columns.invoke(admission.executeValue, fixed.allocator(), &Input{
        .path = config.library,
        .modules = config.native_modules.len,
        .interfaces = config.native_interfaces.len,
        .externals = config.externals.len,
    }) catch unreachable) orelse return null;

    const path = try std.fs.path.resolve(allocator, &.{ root, relative });

    defer allocator.free(path);

    const library = try @import("../library/artifact.zig").open(std.heap.page_allocator, .{
        .io = io,
        .path = path,
        .scopes = scopes,
        .inputs = inputs,
    });

    return .{ .library = library, .instance = root };
}

pub fn deinit(self: *Self) void {
    self.library.deinit();
}

pub fn declaration(self: Self, allocator: std.mem.Allocator, specifier: []const u8) ![]const u8 {
    return identity.declaration(allocator, self.library.program.native_modules, self.instance, specifier);
}

pub fn aliases(self: Self, allocator: std.mem.Allocator, configured: ?[]const model.AbiAlias) ![]const model.AbiAlias {
    return identity.aliases(allocator, self.library.program.native_modules, self.instance, model.AbiAlias, configured);
}
