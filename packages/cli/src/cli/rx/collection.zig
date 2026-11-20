const std = @import("std");
const rx = @import("rx");
const compiler = @import("compiler");
const gateway = @import("rx_analysis").gateway;
const Inputs = @import("watch_inputs").Inputs;
const Text = @import("../sources/text.zig");
const State = @import("collection/state.zig").State;

pub const Options = struct {
    io: std.Io,
    root: []const u8,
    entry: []const u8,
    writer: *std.Io.Writer,
    inputs: ?*Inputs = null,
    project: compiler.project.Options = .{ .entry = "" },
    parse_cache: ?*compiler.project.ParseCache = null,
    libraries: ?*@import("../library/inputs.zig") = null,
    retained_source_allocator: ?std.mem.Allocator = null,
    texts: ?*Text.Cache = null,
};

pub const GatewaySource = struct { path: []const u8, node: rx.ast.Node };
pub const Data = struct { gateway: ?GatewaySource = null, modules: []const rx.ModuleSource, stores: []const rx.ModuleSource, sources: []const rx.TextSource, functions: []const rx.TextSource };

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    data: Data,
    gateway_analysis: ?gateway.Result = null,
    pub fn deinit(self: *Result) void {
        if (self.gateway_analysis) |*analysis| analysis.deinit();

        self.arena.deinit();

        self.* = undefined;
    }

    pub fn takeGateway(self: *Result) ?gateway.Result {
        const analysis = self.gateway_analysis;

        self.gateway_analysis = null;

        return analysis;
    }
};

pub fn load(allocator: std.mem.Allocator, options: Options) !?Result {
    var result: Result = .{ .arena = std.heap.ArenaAllocator.init(allocator), .data = undefined };

    errdefer result.deinit();

    result.data = try State.load(&result, allocator, &options) orelse {
        result.deinit();

        return null;
    };

    return result;
}

pub fn outside(path: []const u8) bool {
    return std.fs.path.isAbsolute(path) or std.mem.eql(u8, path, "..") or std.mem.startsWith(u8, path, "../") or std.mem.startsWith(u8, path, "..\\");
}
