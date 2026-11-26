const std = @import("std");
const zx = @import("zx");
const generating = @import("genz").zx.state;
const modules = @import("../modules.zig");
const Cache = @import("../cache.zig");
const native = if (@import("parser_options").generated_parser) @import("output_execution_abi").layouts.@"zig:state_publication_host" else struct {};
const Error = std.mem.Allocator.Error;
const Self = @This();

bundle: *modules.Bundle,
temporary: std.mem.Allocator,
imports: []const []const u8,
writable: []const bool,
independent: bool,
requirements: generating.Requirements,
cache: ?*Cache,
hash: std.Io.Writer.Hashing(zx.Sha256) = undefined,
key: [32]u8 = undefined,
pub fn run(self: *Self) Error!void {
    const entry = @import("generated_publish_state");
    const Input = std.meta.Child(entry.Input);
    var buffer: [512]u8 = undefined;

    if (self.cache != null) self.hash = .init(&buffer);

    const input: Input = .{
        .frame = @ptrCast(self),
        .name = @import("generated_state_constants").@"zx.constants".state_name,
        .key = &.{
            .writer = @ptrCast(&self.hash.writer),
            .imports = self.imports,
            .writable = self.writable,
            .independent = self.independent,
            .io = self.requirements.io,
            .process = self.requirements.process,
        },
        .cached = self.cache != null,
    };

    entry.executeIn(self.temporary, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };
}

fn borrow(handle: *anyopaque) *Self {
    return @ptrCast(@alignCast(handle));
}

pub fn lookupStateSource(in: *const native.Lookup) Error!?[]const u8 {
    const self = borrow(in.frame);

    self.hash.writer.flush() catch unreachable;
    self.hash.hasher.final(&self.key);

    const source = try self.cache.?.get(in.name, self.key) orelse return null;

    return try self.bundle.arena.allocator().dupe(u8, source);
}

pub fn renderStateSource(handle: *anyopaque) Error![]const u8 {
    const self = borrow(handle);
    const allocator = self.bundle.arena.allocator();
    const names = self.imports[1..];

    if (comptime generating.generated) {
        const columns = generating.ObjectColumns.fromBindings(names, self.writable, self.independent);

        return generating.renderColumns(allocator, columns, self.requirements, true);
    }

    const objects = try @import("objects.zig").create(self.temporary, names, self.writable, self.independent);

    return generating.renderWithCapabilities(allocator, objects, self.requirements);
}

pub fn cacheStateSource(in: *const native.Source) Error!void {
    const self = borrow(in.frame);
    const cache = self.cache.?;
    cache.generated += 1;

    try cache.put(in.name, self.key, in.source);
}

pub fn appendStateFile(in: *const native.File) Error!void {
    const bundle = borrow(in.frame).bundle;
    const old = bundle.modules;
    const files = try bundle.arena.allocator().alloc(modules.File, old.len + 1);

    @memcpy(files[0..old.len], old);

    files[old.len] = .{ .name = in.name, .source = in.source, .imports = in.imports };
    bundle.modules = files;
    bundle.state_module = in.name;
}
