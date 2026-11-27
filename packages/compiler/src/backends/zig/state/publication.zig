const std = @import("std");
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
pub fn run(self: *Self) Error!void {
    const entry = @import("generated_publish_state");
    const Input = std.meta.Child(entry.Input);

    const input: Input = .{
        .frame = @ptrCast(self),
        .name = @import("generated_state_constants").@"zx.constants".state_name,
        .key = &.{
            .imports = self.imports,
            .writable = self.writable,
            .independent = self.independent,
            .io = self.requirements.io,
            .process = self.requirements.process,
        },
        .cached = self.cache != null,
    };

    const publication = @import("zx").columns.invoke(entry.executeIn, self.temporary, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    if (publication.cache_key) |key| {
        const cache = self.cache.?;

        cache.generated += 1;

        try cache.put(publication.name, key[0..32].*, publication.source);
    }

    try self.appendFile(.{ .name = publication.name, .source = publication.source, .imports = publication.imports });
}

fn borrow(handle: *anyopaque) *Self {
    return @ptrCast(@alignCast(handle));
}

pub fn lookupStateSource(in: *const native.Lookup) Error!?[]const u8 {
    const self = borrow(in.frame);
    const key = in.key[0..32].*;
    const source = try self.cache.?.get(in.name, key) orelse return null;

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

fn appendFile(self: *Self, file: modules.File) Error!void {
    const bundle = self.bundle;
    const old = bundle.modules;
    const files = try bundle.arena.allocator().alloc(modules.File, old.len + 1);

    @memcpy(files[0..old.len], old);

    files[old.len] = file;
    bundle.modules = files;
    bundle.state_module = file.name;
}
