const std = @import("std");
const compiler = @import("compiler");
const rx = @import("rx");
const Libraries = @import("../library/inputs.zig");
const Inputs = @import("watch_inputs").Inputs;
const Cursor = @import("preparation/references.zig").Cursor;
const rule = @import("cli_source").prepare_rx_libraries;

pub const Options = struct {
    io: std.Io,
    modules: []const rx.ModuleSource,
    project: compiler.project.Options,
    libraries: *Libraries,
    inputs: ?*Inputs,
    writer: *std.Io.Writer,
};

pub fn collect(allocator: std.mem.Allocator, options: Options) !bool {
    var cursor: Cursor = .{
        .allocator = allocator,
        .io = options.io,
        .project = options.project,
        .modules = options.modules,
        .writer = options.writer,
        .inputs = options.inputs,
        .libraries = options.libraries,
    };

    const reference = &cursor;

    return rule.executeIn(allocator, @ptrCast(&reference)) catch |err| return cursor.failure.unwrap(err);
}
