const std = @import("std");
const node = @import("node.zig");
const Printer = @import("printer.zig");
const Range = @import("node/stored.zig").Declarations;

pub fn render(allocator: std.mem.Allocator, nodes: *@import("node/storage.zig"), declarations: []const node.Declaration) std.mem.Allocator.Error![]u8 {
    return renderStored(allocator, nodes, try nodes.declarations(nodes.allocator, declarations));
}

pub fn renderStored(allocator: std.mem.Allocator, nodes: *@import("node/storage.zig"), selected: Range) std.mem.Allocator.Error![]u8 {
    return renderWithWorkspace(allocator, nodes.allocator, nodes, &.{selected}, false);
}

pub fn renderStoredScoped(allocator: std.mem.Allocator, workspace: std.mem.Allocator, nodes: *@import("node/storage.zig"), ranges: []const Range) std.mem.Allocator.Error![]u8 {
    return renderWithWorkspace(allocator, workspace, nodes, ranges, true);
}

pub fn renderIndices(allocator: std.mem.Allocator, nodes: *@import("node/storage.zig"), indices: []const u32) (std.mem.Allocator.Error || error{InvalidAst})![]u8 {
    if (@import("genz_options").generated) return @import("printer/host.zig").renderIndices(allocator, nodes.allocator, nodes, indices);

    return renderStored(allocator, nodes, try nodes.selectDeclarations(nodes.allocator, indices));
}

fn renderWithWorkspace(allocator: std.mem.Allocator, workspace: std.mem.Allocator, nodes: *@import("node/storage.zig"), ranges: []const Range, comptime scoped: bool) std.mem.Allocator.Error![]u8 {
    if (@import("genz_options").generated) return @import("printer/host.zig").renderStored(allocator, workspace, nodes, ranges, scoped);

    var printer = Printer{ .allocator = allocator, .nodes = nodes };

    defer printer.output.deinit(allocator);

    for (ranges) |range| {
        for (0..range.len) |index| {
            try printer.declaration(nodes.declaration_rows.get(range.start + @as(u32, @intCast(index))));
            try printer.write("\n");
        }
    }

    return printer.output.toOwnedSlice(allocator);
}
