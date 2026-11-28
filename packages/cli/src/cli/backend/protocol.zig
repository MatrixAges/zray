const std = @import("std");
const builtin = @import("builtin");
const Message = std.zig.Server.Message;
pub const Input = struct { prefix: Message.PathPrefix, path: []const u8 };
pub const Mode = enum { application, translation };
pub const process = @import("process.zig");
pub const constants = source.process_constants.@"zx.constants";

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    inputs: []const Input,
    diagnostics: std.zig.ErrorBundle,
    digest: ?[std.Build.Cache.bin_digest_len]u8,
    cached: bool,
    succeeded: bool,
    inputs_complete: bool,
    termination: std.process.Child.Term,
    stderr: []const u8 = "",
    captured_stderr: []u8 = &.{},
    pub fn deinit(self: *Result) void {
        self.arena.child_allocator.free(self.captured_stderr);
        self.arena.deinit();

        self.* = undefined;
    }
    pub fn report(self: *const Result, writer: *std.Io.Writer) !void {
        try writer.writeAll(self.stderr);
        try self.diagnostics.renderToWriter(.{}, writer);
    }
};

pub fn decode(allocator: std.mem.Allocator, stdout: []const u8, stderr: []const u8, termination: std.process.Child.Term) !Result {
    var result = try decodeFrames(allocator, stdout, termination, .application);

    errdefer result.deinit();

    result.stderr = try result.arena.allocator().dupe(u8, stderr);

    return result;
}

const source = @import("cli_source");
const frame_constants = source.frame_constants.@"zx.constants";
pub const diagnostics = @import("error_bundle.zig");

pub const resolveNative = @import("zx").native_lookup.Resolver(&.{
    @This(),
    diagnostics,
    process,
}).resolve;

comptime {
    if (@sizeOf(Message.Header) != frame_constants.frame_header_size or
        @sizeOf(Message.ErrorBundle) != frame_constants.error_bundle_header_size or
        @sizeOf(u32) != frame_constants.word_size or
        @backingInt(Message.Tag.zig_version) != frame_constants.version_tag or
        @backingInt(Message.Tag.error_bundle) != frame_constants.error_bundle_tag or
        @backingInt(Message.Tag.emit_digest) != frame_constants.emit_digest_tag or
        @backingInt(Message.Tag.file_system_inputs) != frame_constants.inputs_tag or
        @backingInt(Message.Tag.config) != frame_constants.config_tag)
    {
        @compileError("Unexpected Zig backend frame layout");
    }

    const prefixes = @typeInfo(Message.PathPrefix).@"enum";

    if (prefixes.field_names.len != frame_constants.path_prefix_limit) @compileError("Unexpected Zig backend path prefix count");

    for (prefixes.field_values, 0..) |value, index| {
        if (value != index) @compileError("Unexpected Zig backend path prefix order");
    }
}

pub fn decodeFrames(allocator: std.mem.Allocator, stdout: []const u8, termination: std.process.Child.Term, mode: Mode) !Result {
    var scratch = std.heap.ArenaAllocator.init(allocator);

    defer scratch.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);

    errdefer arena.deinit();

    const owned = arena.allocator();

    const outcome = try source.decode.executeIn(scratch.allocator(), &.{
        .bytes = stdout,
        .version = builtin.zig_version_string,
        .config_size = @sizeOf(Message.Config),
        .digest_size = std.Build.Cache.bin_digest_len,
        .translation = mode == .translation,
        .exited = termination == .exited and termination.exited == 0,
    });

    switch (outcome.status) {
        .InvalidBackendProtocol => return error.InvalidBackendProtocol,
        .BackendVersionMismatch => return error.BackendVersionMismatch,
        .IncompleteBackendResponse => return error.IncompleteBackendResponse,
        .Success, .SuccessWithInputs, .BackendFailed => {},
    }

    const rows = outcome.paths.rows;
    const inputs = try owned.alloc(Input, rows.len);
    const path_bytes = try owned.alloc(u8, @intCast(outcome.paths.length));
    var offset: usize = 0;

    for (inputs, rows) |*input, row| {
        const path = path_bytes[offset..][0..row.path.len];

        @memcpy(path, row.path);

        input.* = .{ .prefix = @fromBackingInt(@intCast(row.kind)), .path = path };
        offset += path.len;
    }

    const bundle: std.zig.ErrorBundle = if (outcome.diagnostics) |value| .{
        .extra = try owned.dupe(u32, value.words),
        .string_bytes = try owned.dupe(u8, value.strings),
    } else .empty;

    return .{
        .arena = arena,
        .inputs = inputs,
        .diagnostics = bundle,
        .digest = if (outcome.digest) |digest| digest[0..std.Build.Cache.bin_digest_len].* else null,
        .cached = outcome.cached,
        .succeeded = outcome.status != .BackendFailed,
        .inputs_complete = outcome.status == .SuccessWithInputs,
        .termination = termination,
    };
}
