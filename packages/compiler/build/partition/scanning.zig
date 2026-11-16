const std = @import("std");
const parallel = @import("../parallel.zig");
const File = @import("layout.zig").File;
const Scanner = @import("compiler").zig.partition.Scanning;
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

    try parallel.each(arenas, functions.len, &self);

    return self;
}

pub fn step(self: *const Self, allocator: std.mem.Allocator, index: usize) !void {
    const result = try self.scanner.scan(allocator, self.functions[index].source);

    self.callees[index] = result.references.callees;
    self.variants[index] = result.references.variants;
    self.inline_names[index] = result.inline_names;
}
