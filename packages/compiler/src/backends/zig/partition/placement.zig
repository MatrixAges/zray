const std = @import("std");
const layout = @import("layout.zig");
const memory = @import("zxc_standard").memory;

pub const File = struct { path: []const u8, source: []const u8 };

pub fn publish(allocator: std.mem.Allocator, functions: []const File, paths: []const []const u8, plan: *const layout.Plan) std.mem.Allocator.Error![]File {
    const generated = @import("generated_partition_placement");
    const Input = std.meta.Child(generated.Input);
    const State = std.meta.Child(@FieldType(Input, "files"));
    const files = try allocator.alloc(File, @intCast(plan.placement.length));

    errdefer allocator.free(files);

    const bodies = memory.borrowTextColumn("source", functions);
    const destinations = memory.borrowWriteColumn([]const u8, "path", files);
    const sources = memory.borrowWriteColumn([]const u8, "source", files);

    const state: State = .{
        .paths = paths,
        .bodies = @ptrCast(&bodies),
        .target_paths = @ptrCast(&destinations),
        .target_sources = @ptrCast(&sources),
    };

    const counts: std.meta.Child(@FieldType(Input, "placement")) = .{
        .first_stub = plan.placement.first_stub,
        .first_root = plan.placement.first_root,
        .length = plan.placement.length,
    };

    const input: Input = .{
        .files = &state,
        .members = plan.members,
        .scopes = plan.scopes,
        .placement = &counts,
    };

    generated.executeValue(allocator, &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.debug.panic("invalid partition placement: {s}", .{@errorName(err)}),
    };

    return files;
}
