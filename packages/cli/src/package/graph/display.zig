const std = @import("std");
const pkgs = @import("pkgs");
const Graph = @import("../graph.zig");

const Edges = struct {
    rows: []const pkgs.Lock.Dependency,
    pub fn jsonStringify(self: Edges, writer: *std.json.Stringify) std.Io.Writer.Error!void {
        try writer.beginArray();

        for (self.rows) |*row| {
            try writer.write(Graph.Dependency{ .name = row.name, .target = row.target, .development = row.development });
        }

        try writer.endArray();
    }
};

pub fn write(result: *const Graph.Result, output: *std.Io.Writer) std.Io.Writer.Error!void {
    const options: std.json.Stringify.Options = .{ .whitespace = .indent_2 };

    if (result.locked) |locked| {
        var writer: std.json.Stringify = .{ .writer = output, .options = options };

        try writer.beginArray();

        for (result.packages, locked) |*package, *row| {
            try writer.write(.{
                .path = package.path,
                .manifest = package.manifest,
                .dependencies = Edges{ .rows = row.dependencies },
            });
        }

        try writer.endArray();
    } else {
        try std.json.Stringify.value(result.packages, options, output);
    }
}
