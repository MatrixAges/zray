const std = @import("std");
const zx = @import("zx");
const memory = zx.memory;
const generated = @import("parser_options").generated_parser;
const seed = @import("interface_seed.zig");
pub const Location = struct { source: u64 };
pub const Job = struct { source: u64, binding: u64, name: []const u8 };

pub fn sourceRow(index: u64) ?usize {
    return if (index == std.math.maxInt(u64)) null else @intCast(index);
}

pub fn locate(declarations: anytype, candidates: anytype, matches: []Location) void {
    if (declarations.len == 0) return;
    if (comptime !generated) return seed.locate("key", declarations, candidates, matches);

    const rule = @import("generated_input_interface_location");
    const paths = memory.borrowTextColumn("path", declarations);
    const keys = memory.borrowTextColumn("key", candidates);
    const output = memory.borrowWriteColumn(u64, "source", matches);
    const input = location(std.meta.Child(rule.Input), &paths, &keys, declarations.len, candidates.len, &output, false);
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;
}

pub fn register(allocator: std.mem.Allocator, declarations: anytype, sources: anytype, jobs: []Job) !usize {
    if (declarations.len == 0) return 0;
    if (comptime !generated) return seed.register(allocator, declarations, sources, jobs);

    const rule = @import("generated_input_interface_registration");
    const Input = std.meta.Child(rule.Input);
    const paths = memory.borrowTextColumn("path", declarations);
    const candidates = memory.borrowTextColumn("path", sources);
    const output = memory.borrowWriteColumn(u64, "source", jobs);
    const modules = memory.borrowTextColumn("module", declarations);
    const specifiers = memory.borrowReadColumn(?[]const u8, "specifier", declarations);
    const bindings = memory.borrowWriteColumn(u64, "binding", jobs);
    const names = memory.borrowWriteColumn([]const u8, "name", jobs);
    const lookup = location(std.meta.Child(@FieldType(Input, "location")), &paths, &candidates, declarations.len, sources.len, &output, true);

    const input: Input = .{
        .location = &lookup,
        .target = &.{
            .aliases = &.{ .specifiers = @ptrCast(&specifiers), .count = declarations.len },
            .modules = @ptrCast(&modules),
            .bindings = @ptrCast(&bindings),
            .names = @ptrCast(&names),
        },
    };

    return @intCast(try zx.columns.invoke(rule.executeValue, allocator, &input));
}

fn location(comptime Input: type, paths: *const memory.TextColumn, candidates: *const memory.TextColumn, declarations: usize, count: usize, output: *const memory.WriteColumn, sorted: bool) Input {
    return .{
        .paths = @ptrCast(paths),
        .candidates = @ptrCast(candidates),
        .declarations = declarations,
        .count = count,
        .output = @ptrCast(output),
        .sorted = sorted,
    };
}
