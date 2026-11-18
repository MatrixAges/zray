const std = @import("std");
const frontend = @import("frontend");
const rx = @import("rx");
const zx = @import("zx");
const Module = @import("module.zig");
const SourceMap = @import("source_map.zig");
const Inputs = @import("project/call_inputs.zig");
const target = @import("call/target.zig");
pub const source_graph = @import("project/source_graph.zig");
pub const History = @import("project/history.zig").History;

comptime {
    if (@import("rx_options").generated_graph) _ = @import("project/workflow/effects.zig");
}

pub const ModuleDigest = @import("project/history.zig").Digest;

pub const Options = struct {
    entry: []const u8,
    exports: []const Export = &.{},
    modules: []const rx.ModuleSource,
    stores: []const rx.ModuleSource = &.{},
    sources: []const frontend.project.Source,
    project: frontend.project.Options = .{ .entry = "" },
    /// Backing for temporary analysis arenas when `allocator` itself retains freed allocations.
    scratch_allocator: ?std.mem.Allocator = null,
    /// Shared with earlier source graph passes so each module is parsed once; it must outlive the result.
    parse_cache: ?*frontend.project.ParseCache = null,
    /// Reuses modules of the analysis it names; the parse cache must then keep the results that analysis used.
    history: ?*History = null,
};

pub const Export = struct { name: []const u8, path: []const u8 };

pub fn infer(allocator: std.mem.Allocator, options: Options) std.mem.Allocator.Error!Module.Result {
    var arena = std.heap.ArenaAllocator.init(allocator);

    errdefer arena.deinit();

    const value = try inferIn(arena.allocator(), options.scratch_allocator orelse allocator, options);

    return .{ .arena = arena, .value = value };
}

fn inferIn(allocator: std.mem.Allocator, backing: std.mem.Allocator, options: Options) std.mem.Allocator.Error!Module.Value {
    var local = frontend.project.ParseCache{ .allocator = allocator };

    defer local.deinit();

    var inputs: Inputs = .{ .arena = .init(backing) };

    defer inputs.arena.deinit();

    var state: @import("project/workflow/infer/host.zig").State = .{
        .allocator = allocator,
        .backing = backing,
        .options = options,
        .cache = options.parse_cache orelse &local,
        .inputs = &inputs,
    };

    return state.run();
}

pub fn report(allocator: std.mem.Allocator, source_map: SourceMap, reporter: zx.Reporter, err: zx.Error) std.mem.Allocator.Error!Module.Value {
    if (err == error.OutOfMemory) return error.OutOfMemory;

    const issue = reporter.diagnostic.?;
    const origin = source_map.locate(issue.span.start).?;

    return failure(allocator, .{ .path = origin.path, .location = origin.location, .code = @tagName(issue.code), .message = issue.message });
}

pub fn failure(allocator: std.mem.Allocator, issue: target.Diagnostic) std.mem.Allocator.Error!Module.Value {
    const value = try target.failure(allocator, issue);

    return .{ .diagnostic = value.diagnostic };
}

pub fn remap(allocator: std.mem.Allocator, options: Options, issue: target.Diagnostic) std.mem.Allocator.Error!Module.Value {
    for (options.sources) |source| {
        if (source.template_origins.len == 0) continue;

        const path = try std.fs.path.resolve(allocator, &.{ options.project.root_dir, source.path });

        if (!std.mem.eql(u8, path, issue.path)) continue;

        const origin = frontend.project.resources.locate(source, issue.location.offset);
        const position = zx.source.locate(origin.source, origin.offset);

        return failure(allocator, .{ .path = origin.path, .location = .{ .offset = origin.offset, .line = position.line, .column = position.column }, .code = issue.code, .message = issue.message });
    }

    return failure(allocator, issue);
}
