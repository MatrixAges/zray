const std = @import("std");
const compiler = @import("compiler");
const seed_interfaces = compiler.source_inputs.interface_seed;
const Resident = @import("resident/state.zig");
const Interface = @import("generation_manifest.zig").Interface;
const Native = compiler.project.NativeInterface;
const generated = compiler.input_generation.generated;
const Binding = if (generated) @import("generation_execution_abi").layouts.@"zig:generation_host".NativeBinding else SeedBinding;
const SeedBinding = struct { index: usize, name: []const u8, path: []const u8, module: []const u8, source: []const u8, resolve_members: bool };
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
    fn write(self: *Loader, row: *const Binding) Error!void {
        self.bindings[@intCast(row.index)] = .{
            .specifier = try self.resident.retainText(self.owned, row.name),
            .path = try self.resident.retainText(self.owned, row.path),
            .source = row.source,
            .namespace = if (row.resolve_members) &.{compiler.native_lookup.marker} else &.{},
            .module = try self.resident.retainText(self.owned, row.module),
        };
    }

    fn publish(self: *Loader, declarations: []const Interface, sources: []const compiler.project.Source) !usize {
        const rule = @import("generated_input_interface_registration");
        const memory = @import("zx").memory;
        const paths = memory.borrowTextColumn("path", declarations);
        const modules = memory.borrowTextColumn("module", declarations);
        const specifiers = memory.borrowReadColumn(?[]const u8, "specifier", declarations);
        const namespaces = memory.borrowReadColumn(?bool, "resolve_members", declarations);
        const source_paths = memory.borrowTextColumn("path", sources);
        const bodies = memory.borrowTextColumn("source", sources);

        return @intCast(try rule.executeIn(self.scratch, &.{
            .loader = @ptrCast(self),
            .aliases = &.{ .specifiers = @ptrCast(&specifiers), .count = declarations.len },
            .paths = @ptrCast(&paths),
            .modules = @ptrCast(&modules),
            .namespaces = @ptrCast(&namespaces),
            .sources = &.{ .paths = @ptrCast(&source_paths), .bodies = @ptrCast(&bodies), .count = sources.len },
        }));
    }

    fn seed(self: *Loader, declarations: []const Interface, sources: []const compiler.project.Source) !usize {
        const Job = struct { source: ?usize, binding: usize, name: []const u8 };
        const jobs = try self.scratch.alloc(Job, declarations.len);
        const external = try seed_interfaces.register(self.scratch, declarations, sources, jobs);

        for (declarations, jobs) |entry, job| {
            const source = if (job.source) |row| sources[row].source else try self.read(entry.path);

            try self.write(&.{
                .index = job.binding,
                .name = job.name,
                .path = entry.path,
                .module = entry.module,
                .source = source,
                .resolve_members = entry.resolve_members == true,
            });
        }

        return external;
    }
};

pub fn loadNativeText(handle: *const anyopaque, path: []const u8) Error![]const u8 {
    const self: *Loader = @ptrCast(@alignCast(@constCast(handle)));

    return self.read(path);
}

pub fn writeNativeBinding(handle: *const anyopaque, input: *const Binding) Error!void {
    const self: *Loader = @ptrCast(@alignCast(@constCast(handle)));

    return self.write(input);
}
