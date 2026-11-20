const std = @import("std");
const compiler = @import("compiler");
const Inputs = @import("watch_inputs").Inputs;
const codec = compiler.library.codec;
const constants = @import("cli_source").compiled_artifact_constants.@"zx.constants";

pub const Request = struct {
    io: std.Io,
    path: []const u8,
    scopes: []const compiler.project.PackageScope,
    inputs: ?*Inputs,
};

const raw = std.heap.page_allocator;

pub fn open(allocator: std.mem.Allocator, request: Request) !compiler.library.Result {
    const bytes = try read(request);

    defer raw.free(bytes);

    return codec.decode(allocator, bytes);
}

pub fn openIndexed(allocator: std.mem.Allocator, request: Request) !codec.Indexed {
    const bytes = try read(request);

    defer raw.free(bytes);

    return codec.decodeIndexed(allocator, bytes);
}

fn read(request: Request) ![]u8 {
    const path = request.path;
    var paths = std.heap.ArenaAllocator.init(raw);

    defer paths.deinit();

    if (request.inputs) |observed| try observed.add(request.io, path);
    try @import("../../package/source.zig").validateWithInputs(request.io, paths.allocator(), path, request.scopes, request.inputs);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(request.io, path, raw, .limited(constants.artifact_limit));

    errdefer raw.free(bytes);

    if (request.inputs) |observed| try observed.record(request.io, path, bytes);

    return bytes;
}
