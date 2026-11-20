const std = @import("std");
const manifest = @import("../manifest.zig");
const Inputs = @import("watch_inputs").Inputs;
const Manifest = @import("model.zig").Manifest;
const manifest_limit = 4 * 1024 * 1024;

pub const File = struct {
    path: []const u8,
    physical: []const u8,
};

pub const Known = struct {
    file: File,
    data: Manifest,
    pub fn matches(self: Known, file: File) bool {
        return std.mem.eql(u8, self.file.path, file.path) and std.mem.eql(u8, self.file.physical, file.physical);
    }
};

pub fn locate(io: std.Io, allocator: std.mem.Allocator, path: []const u8, inputs: ?*Inputs) !File {
    if (inputs) |observed| try observed.add(io, path);

    const physical = try std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);

    return .{ .path = path, .physical = physical };
}

pub fn decode(io: std.Io, allocator: std.mem.Allocator, file: File, inputs: ?*Inputs) !manifest.Value {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, file.physical, std.heap.smp_allocator, .limited(manifest_limit));

    defer std.heap.smp_allocator.free(bytes);

    if (inputs) |observed| try observed.record(io, file.path, bytes);

    return manifest.parseInto(allocator, bytes);
}

pub fn diagnostic(allocator: std.mem.Allocator, path: []const u8, issue: @import("model.zig").Diagnostic) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}:{d}:{d}: manifest: {s}", .{ path, issue.line, issue.column, issue.message });
}
