const std = @import("std");
const layout = @import("layout.zig");
const memory = @import("zx").memory;
pub const File = struct { path: []const u8, source: []const u8 };
pub const Stub = struct { callee: u32, variants: []const []const u8, comptime_entry: bool };
pub const Publication = struct { files: []File, stubs: []const Stub };

pub fn publish(allocator: std.mem.Allocator, temporary: std.mem.Allocator, functions: []const File, paths: []const []const u8, plan: *const layout.Plan) std.mem.Allocator.Error!Publication {
    const generated = @import("generated_partition_placement");
    const Input = std.meta.Child(generated.Input);
    const State = std.meta.Child(@FieldType(Input, "files"));
    const files = try allocator.alloc(File, @intCast(plan.placement.length));

    errdefer allocator.free(files);

    const stubs = try temporary.alloc(Stub, @intCast(plan.placement.first_root - plan.placement.first_stub));

    errdefer temporary.free(stubs);

    const bodies = memory.borrowTextColumn("source", functions);
    const destinations = memory.borrowWriteColumn([]const u8, "path", files);
    const sources = memory.borrowWriteColumn([]const u8, "source", files);
    const callees = memory.borrowWriteColumn(u32, "callee", stubs);
    const variants = memory.borrowWriteColumn([]const []const u8, "variants", stubs);
    const comptime_entries = memory.borrowWriteColumn(bool, "comptime_entry", stubs);

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
        .stub_targets = &.{ .callees = @ptrCast(&callees), .variants = @ptrCast(&variants), .comptime_entries = @ptrCast(&comptime_entries) },
    };

    generated.executeValue(allocator, &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.debug.panic("invalid partition placement: {s}", .{@errorName(err)}),
    };

    return .{ .files = files, .stubs = stubs };
}
