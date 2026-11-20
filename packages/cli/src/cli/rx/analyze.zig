const std = @import("std");
const compiler = @import("compiler");
const analysis = @import("rx_analysis");
const preparation = @import("preparation/project.zig");
const Inputs = @import("watch_inputs").Inputs;
const Text = @import("../sources/text.zig");
pub const Result = struct { analysis: compiler.AnalysisResult, sources: []const compiler.project.Source, store_definitions: []const analysis.store.Definition };

pub const Options = struct {
    io: std.Io,
    project: compiler.project.Options,
    writer: *std.Io.Writer,
    parse_cache: *compiler.project.ParseCache,
    inputs: ?*Inputs = null,
    exports: []const analysis.project.Export = &.{},
    texts: ?*Text.Cache = null,
};

pub fn run(allocator: std.mem.Allocator, options: Options) !?Result {
    return preparation.run(allocator, &options);
}
