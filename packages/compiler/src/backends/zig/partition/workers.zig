const std = @import("std");
const zx = @import("zx");
const parallel = @import("../output/parallel.zig");
const File = @import("../partition.zig").File;
const Scanner = @import("../partition.zig").Scanning;
const Self = @This();
const generated = @import("parser_options").generated_parser;

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

    if (comptime generated) {
        const sources = zx.memory.borrowTextColumn("source", functions);
        const Scan = std.meta.Child(@typeInfo(@FieldType(parallel.Request, "scan")).optional.child);
        const index = zx.columns.borrow(std.meta.Child(@FieldType(Scan, "index")), &scanner.index);

        try parallel.eachScan(arenas, .{
            .count = batches,
            .hash = null,
            .write = null,
            .scan = &.{ .sources = @ptrCast(&sources), .index = &index, .length = functions.len },
        }, .{
            .callees = self.callees,
            .variants = self.variants,
            .inline_names = self.inline_names,
        });
    } else {
        try parallel.eachSeed(arenas, batches, &self);
    }

    return self;
}

pub fn step(self: *const Self, allocator: std.mem.Allocator, index: usize) !void {
    const first = index * Scanner.batch_size;
    const end = @min(first + Scanner.batch_size, self.functions.len);

    try self.scan(allocator, first, end);
}

fn scan(self: *const Self, allocator: std.mem.Allocator, first: usize, end: usize) Scanner.Error!void {
    try self.scanner.scan(allocator, self.functions[first..end], .{
        .callees = self.callees[first..end],
        .variants = self.variants[first..end],
        .inline_names = self.inline_names[first..end],
    });
}
