const std = @import("std");
const compiler = @import("compiler");
const seed_interfaces = compiler.source_inputs.interface_seed;
const Resident = @import("resident/state.zig");
const Interface = @import("generation_manifest.zig").Interface;
const Native = compiler.project.NativeInterface;
const generated = compiler.input_generation.generated;
const Binding = struct { index: usize, name: []const u8, path: []const u8, module: []const u8, source: []const u8, resolve_members: bool };
const Error = std.mem.Allocator.Error;

pub const Result = struct {
    bindings: []const Native,
    external: usize,
    failure: ?anyerror,
};

pub fn load(io: std.Io, scratch: std.mem.Allocator, owned: std.mem.Allocator, resident: *Resident, declarations: []const Interface, sources: []const compiler.project.Source) !Result {
    if (declarations.len == 0) return .{ .bindings = &.{}, .external = 0, .failure = null };

    var loader: Loader = .{
        .io = io,
        .scratch = scratch,
        .owned = owned,
        .resident = resident,
        .bindings = try owned.alloc(Native, declarations.len),
    };

    const external = if (comptime generated)
        try loader.publish(declarations, sources)
    else
        try loader.seed(declarations, sources);

    return .{ .bindings = loader.bindings, .external = external, .failure = loader.read_failure };
}

const Loader = struct {
    io: std.Io,
    scratch: std.mem.Allocator,
    owned: std.mem.Allocator,
    resident: *Resident,
    bindings: []Native,
    read_failure: ?anyerror = null,
    fn read(self: *Loader, path: []const u8) Error![]const u8 {
        const key = try std.fs.path.resolve(self.scratch, &.{path});

        return self.resident.files.read(self.io, .cwd(), path, key, true) catch |err| {
            if (self.read_failure == null) self.read_failure = err;

            return "";
        };
    }
    fn write(self: *Loader, row: Binding, temporary_name: bool) Error!void {
        self.bindings[row.index] = .{
            .specifier = if (temporary_name) try self.owned.dupe(u8, row.name) else try self.resident.retainText(self.owned, row.name),
            .path = try self.resident.retainText(self.owned, row.path),
            .source = row.source,
            .namespace = if (row.resolve_members) &.{compiler.native_lookup.marker} else &.{},
            .module = try self.resident.retainText(self.owned, row.module),
        };
    }

    fn publish(self: *Loader, declarations: []const Interface, sources: []const compiler.project.Source) !usize {
        const rule = @import("generated_input_interface_registration");
        const memory = @import("zx").memory;
        const Input = std.meta.Child(rule.Input);
        const declared = memory.borrowReadFields(.{ .paths = "path", .modules = "module", .namespaces = "resolve_members" }, declarations);
        const aliases = memory.borrowReadFields(.{ .specifiers = "specifier" }, declarations);
        const views = memory.borrowReadFields(.{ .paths = "path", .bodies = "source" }, sources);

        var input: Input = undefined;

        declared.fill(&input);

        const specifiers = aliases.bind(std.meta.Child(@FieldType(Input, "aliases")));
        const files = views.bind(std.meta.Child(@FieldType(Input, "sources")));

        input.aliases = &specifiers;
        input.sources = &files;

        var arena = std.heap.ArenaAllocator.init(self.scratch);

        defer arena.deinit();

        const plan = try rule.executeIn(arena.allocator(), &input);

        for (plan.bindings) |row| {
            try self.write(.{
                .index = @intCast(row.index),
                .name = row.name,
                .path = row.path,
                .module = row.module,
                .source = if (row.read_path) |path| try self.read(path) else row.source,
                .resolve_members = row.resolve_members,
            }, row.index >= plan.external);
        }

        return @intCast(plan.external);
    }
    fn seed(self: *Loader, declarations: []const Interface, sources: []const compiler.project.Source) !usize {
        const Job = struct { source: ?usize, binding: usize, name: []const u8 };
        const jobs = try self.scratch.alloc(Job, declarations.len);
        const external = try seed_interfaces.register(self.scratch, declarations, sources, jobs);

        for (declarations, jobs) |entry, job| {
            const source = if (job.source) |row| sources[row].source else try self.read(entry.path);

            try self.write(.{
                .index = job.binding,
                .name = job.name,
                .path = entry.path,
                .module = entry.module,
                .source = source,
                .resolve_members = entry.resolve_members == true,
            }, false);
        }

        return external;
    }
};
