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

    if (@backingInt(Prefix.zig_lib) != constants.prefix_zig_lib or
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
bindings: ?@import("publication_host").application.Bindings = null,
pub fn deinit(self: *Self) void {
    self.response.deinit();

    self.* = undefined;
}

pub fn resolve(io: std.Io, response: *Response, cache: Cache, library: []const u8, options: Options, inputs: *Inputs) !Self {
    return resolveBatches(io, response, &.{}, cache, library, options, inputs, response.arena.allocator());
}

pub fn resolveBatches(io: std.Io, response: *Response, translations: []const Response, cache: Cache, library: []const u8, options: Options, inputs: *Inputs, path_allocator: std.mem.Allocator) !Self {
    const allocator = response.arena.allocator();
    var context: host.Context = .{ .io = io, .owned = path_allocator, .inputs = inputs, .translations = translations, .response = response };

    const observation = source.backend_inputs.executeIn(allocator, &.{
        .dependencies = @ptrCast(&context),
        .roots = &.{ .cwd = cache.cwd, .local = cache.local, .global = cache.global, .library = library },
        .batches = translations.len + 1,
    }) catch |err| return if (err == error.BackendInputFailure) context.failure.? else err;

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

    return .{ .response = result, .input_paths = context.paths, .new_inputs = observation.new_inputs, .binary = binary, .assembly = assembly };
}

pub fn publish(self: *const Self, io: std.Io, allocator: std.mem.Allocator, inputs: *Inputs, options: Options) !bool {
    const host_publication = @import("publication_host");
    var failure: host_publication.Failure = .{};

    var publication: host_publication.application = .{
        .io = io,
        .allocator = allocator,
        .failure = &failure,
        .inputs = inputs,
        .binary = .{ .source = self.binary, .destination = options.output },
        .assembly = .{ .source = self.assembly, .destination = options.assembly },
        .bindings = self.bindings,
    };

    defer publication.deinit();

    var verification: host_publication.verification = .{
        .io = io,
        .allocator = allocator,
        .snapshot_allocator = if (inputs.retain_versions) inputs.arena.child_allocator else allocator,
        .inputs = inputs,
        .failure = &failure,
    };

    defer verification.deinit();

    const result = source.publish_observed.executeIn(allocator, &.{
        .publication = @ptrCast(&publication),
        .verification = @ptrCast(&verification),
        .succeeded = self.response.succeeded,
        .complete = self.response.inputs_complete,
        .new_inputs = self.new_inputs,
        .requested_assembly = options.assembly != null,
        .emitted_assembly = self.assembly != null,
        .bindings = self.bindings != null,
    }) catch |err| return failure.unwrap(err);

    return switch (result) {
        .Skipped => false,
        .ConflictingPaths => error.ConflictingOutputPaths,
        .Published => true,
    };
}
