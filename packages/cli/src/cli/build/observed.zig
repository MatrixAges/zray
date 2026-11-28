const std = @import("std");
const builtin = @import("builtin");
const Inputs = @import("watch_inputs").Inputs;
const Options = @import("../options.zig").Options;
const Response = @import("backend_protocol").Result;
const Self = @This();
const host = @import("backend_input_host");
const source = @import("cli_source");
const constants = source.backend_cache_constants.@"zx.constants";

pub const artifact_name = constants.artifact_name;

comptime {
    const Prefix = std.zig.Server.Message.PathPrefix;

    if (@typeInfo(Prefix).@"enum".tag_type != u8 or
        @backingInt(Prefix.zig_lib) != constants.prefix_zig_lib or
        @backingInt(Prefix.local_cache) != constants.prefix_local_cache or
        @backingInt(Prefix.global_cache) != constants.prefix_global_cache)
    {
        @compileError("Unexpected Zig dependency prefix values");
    }
}

pub const Cache = struct {
    cwd: []const u8,
    local: []const u8,
    global: []const u8,
    pub fn init(io: std.Io, allocator: std.mem.Allocator, environment: *const std.process.Environ.Map) !Cache {
        const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
        const global = environment.get("ZIG_GLOBAL_CACHE_DIR") orelse try std.fs.path.join(allocator, &.{ try @import("toolchain_cache").root(allocator, environment), "backend" });

        return .{
            .cwd = cwd,
            .local = try std.fs.path.resolve(allocator, &.{ cwd, ".zxc", "cache", "backend" }),
            .global = try std.fs.path.resolve(allocator, &.{ cwd, global }),
        };
    }
};

response: Response,
input_paths: []const []const u8,
new_inputs: bool,
binary: ?[]const u8,
assembly: ?[]const u8,
bindings: ?@import("publication_host").bindings = null,
pub fn deinit(self: *Self) void {
    self.response.deinit();

    self.* = undefined;
}

pub fn resolve(io: std.Io, response: *Response, cache: Cache, library: []const u8, options: Options, inputs: *Inputs) !Self {
    return resolveBatches(io, response, &.{}, cache, library, options, inputs, response.arena.allocator());
}

pub fn resolveBatches(io: std.Io, response: *Response, translations: []const Response, cache: Cache, library: []const u8, options: Options, inputs: *Inputs, path_allocator: std.mem.Allocator) !Self {
    const allocator = response.arena.allocator();
    var scratch = std.heap.ArenaAllocator.init(allocator);

    defer scratch.deinit();

    const temporary = scratch.allocator();
    const Entry = source.backend_inputs;
    const Batch = std.meta.Child(std.meta.Child(@FieldType(std.meta.Child(Entry.Input), "batches")));
    const memory = @import("zx").memory;
    const batch_count = translations.len + 1;
    const batches = try temporary.alloc(*const Batch, batch_count);
    const values = try temporary.alloc(Batch, batch_count);
    const paths = try temporary.alloc(memory.TextColumn, batch_count);
    const prefixes = try temporary.alloc(memory.ReadColumn, batch_count);

    for (batches, values, paths, prefixes, 0..) |*batch, *value, *path, *prefix, index| {
        const current = if (index < translations.len) &translations[index] else response;

        path.* = memory.borrowTextColumn("path", current.inputs);
        prefix.* = memory.borrowReadColumn(std.zig.Server.Message.PathPrefix, "prefix", current.inputs);

        value.* = .{
            .paths = @ptrCast(path),
            .prefixes = @ptrCast(prefix),
            .count = current.inputs.len,
            .complete = current.inputs_complete,
        };

        batch.* = value;
    }

    var context: host.Registration = .{ .io = io, .inputs = inputs };
    const registration = &context;

    const observation = Entry.executeIn(path_allocator, &.{
        .registration = @ptrCast(&registration),
        .roots = &.{ .cwd = cache.cwd, .local = cache.local, .global = cache.global, .library = library },
        .batches = batches,
    }) catch |err| return if (err == error.ObservationFailure) context.failure.? else err;

    var binary: ?[]const u8 = null;
    var assembly: ?[]const u8 = null;

    if (response.succeeded) {
        const target = if (options.target) |triple| try std.zig.system.resolveTargetQuery(io, try std.Target.Query.parse(.{ .arch_os_abi = triple })) else builtin.target;
        const name = try std.zig.binNameAlloc(allocator, .{ .root_name = artifact_name, .cpu_arch = target.cpu.arch, .os_tag = target.os.tag, .ofmt = target.ofmt, .abi = target.abi, .output_mode = if (options.host == .node) .Lib else .Exe, .link_mode = if (options.host == .node) .dynamic else .static });
        const hash = std.fmt.bytesToHex(response.digest.?, .lower);

        const files = try source.backend_cached_artifacts.executeValue(allocator, &.{
            .root = cache.local,
            .hash = &hash,
            .executable = name,
            .separator = &.{std.fs.path.sep},
            .assembly = options.assembly != null,
        });

        binary = files.binary;
        assembly = files.assembly;
    }

    var result = response.*;

    result.inputs_complete = observation.complete;

    return .{ .response = result, .input_paths = observation.paths, .new_inputs = observation.new_inputs, .binary = binary, .assembly = assembly };
}

pub fn publish(self: *const Self, io: std.Io, allocator: std.mem.Allocator, inputs: *Inputs, options: Options) !bool {
    const host_publication = @import("publication_host");
    var failure: host_publication.Failure = .{};

    var verification: host_publication.verification = .{
        .io = io,
        .allocator = allocator,
        .snapshot_allocator = if (inputs.retain_versions) inputs.arena.child_allocator else allocator,
        .inputs = inputs,
        .failure = &failure,
    };

    defer verification.deinit();

    const observation = &verification;
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const Entry = source.publish_observed;
    const Binding = std.meta.Child(std.meta.Child(@FieldType(std.meta.Child(Entry.Input), "bindings")));

    const bindings: Binding = if (self.bindings) |files| .{
        .module = files.module_path,
        .declaration = files.declaration_path,
        .module_source = files.module_source,
        .declaration_source = files.declarations,
    } else undefined;

    const result = Entry.executeIn(arena.allocator(), &.{
        .binary_source = self.binary,
        .binary_target = options.output.?,
        .assembly_source = self.assembly,
        .assembly_target = options.assembly,
        .verification = @ptrCast(&observation),
        .versioned = inputs.retain_versions,
        .succeeded = self.response.succeeded,
        .complete = self.response.inputs_complete,
        .new_inputs = self.new_inputs,
        .bindings = if (self.bindings != null) &bindings else null,
    }, io) catch |err| return failure.unwrap(err);

    return switch (result) {
        .Skipped => false,
        .ConflictingPaths => error.ConflictingOutputPaths,
        .ForeignFile => error.NodeBindingWouldOverwriteFile,
        .Published => true,
    };
}
