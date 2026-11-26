const std = @import("std");
const parallel = @import("../output/parallel.zig");
const File = @import("placement.zig").File;
const Scanner = @import("../partition.zig").Scanning;
const Self = @This();

functions: []const File,
scanner: *const Scanner,
callees: [][]const u32,
variants: [][]const []const u8,
inline_names: [][]const []const u8,
pub fn run(allocator: std.mem.Allocator, arenas: parallel.Arenas, functions: []const File, scanner: *const Scanner) !Self {
    const self = Self{
        .functions = functions,
        .scanner = scanner,
        .callees = try allocator.alloc([]const u32, functions.len),
        .variants = try allocator.alloc([]const []const u8, functions.len),
        .inline_names = try allocator.alloc([]const []const u8, functions.len),
    };

    const batches = std.math.divCeil(usize, functions.len, Scanner.batch_size) catch unreachable;

    try parallel.each(arenas, batches, &self);

    return self;
}

pub fn step(self: *const Self, allocator: std.mem.Allocator, index: usize) !void {
    const first = index * Scanner.batch_size;
    const end = @min(first + Scanner.batch_size, self.functions.len);

    try self.scanner.scan(allocator, self.functions[first..end], .{
        .callees = self.callees[first..end],
        .variants = self.variants[first..end],
        .inline_names = self.inline_names[first..end],
    });
}
