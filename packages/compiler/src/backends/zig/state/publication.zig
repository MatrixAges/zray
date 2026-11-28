const std = @import("std");
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
    const entry = @import("generated_publish_state");
    const Input = std.meta.Child(entry.Input);
    const Lookup = std.meta.Child(@typeInfo(@FieldType(Input, "lookup")).optional.child);

    var input: Input = .{
        .name = @import("generated_state_constants").@"zx.constants".state_name,
        .key = &.{
            .imports = self.imports,
            .writable = self.writable,
            .independent = self.independent,
            .io = self.requirements.io,
            .process = self.requirements.process,
        },
        .cached = self.cache != null,
        .lookup = null,
    };

    var publication = entry.executeIn(self.temporary, &input) catch |err| return failure(err);

    if (publication.action == .Lookup) {
        const key = publication.cache_key.?;

        const lookup: Lookup = .{
            .key = key,
            .source = try self.cache.?.get(publication.name, key[0..32].*),
        };

        input.lookup = &lookup;
        publication = entry.executeIn(self.temporary, &input) catch |err| return failure(err);
    }

    const allocator = self.bundle.arena.allocator();

    const source = switch (publication.action) {
        .Lookup => unreachable,
        .Reuse => try allocator.dupe(u8, publication.source.?),
        .Render => try self.render(allocator),
    };

    if (publication.cache_key) |key| {
        const cache = self.cache.?;

        cache.generated += 1;

        try cache.put(publication.name, key[0..32].*, source);
    }

    try self.appendFile(.{ .name = publication.name, .source = source, .imports = publication.imports });
}

fn render(self: *const Self, allocator: std.mem.Allocator) Error![]const u8 {
    const names = self.imports[1..];

    if (comptime generating.generated) {
        const columns = generating.ObjectColumns.fromBindings(names, self.writable, self.independent);

        return generating.renderColumns(allocator, columns, self.requirements, true);
    }

    const objects = try @import("objects.zig").create(self.temporary, names, self.writable, self.independent);

    return generating.renderWithCapabilities(allocator, objects, self.requirements);
}

fn failure(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => error.OutOfMemory,
        else => unreachable,
    };
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
