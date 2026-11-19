const std = @import("std");
const layout = @import("layout.zig");
const memory = @import("zx").memory;
pub const File = struct { path: []const u8, source: []const u8 };

pub const Job = struct {
    destination: u64,
    index: u32,
    root: bool,
    variants: []const []const u8,
    comptime_entry: bool,
};

pub const Publication = struct { files: []File, jobs: []const Job };

pub fn publish(allocator: std.mem.Allocator, temporary: std.mem.Allocator, functions: []const File, paths: []const []const u8, plan: *const layout.Plan) std.mem.Allocator.Error!Publication {
    const generated = @import("generated_partition_placement");
    const Input = std.meta.Child(generated.Input);
    const State = std.meta.Child(@FieldType(Input, "files"));
    const files = try allocator.alloc(File, @intCast(plan.placement.length));

    errdefer allocator.free(files);

    const jobs = try temporary.alloc(Job, @intCast(plan.placement.jobs));

    errdefer temporary.free(jobs);

    const bodies = memory.borrowTextColumn("source", functions);
    const destinations = memory.borrowWriteColumn([]const u8, "path", files);
    const sources = memory.borrowWriteColumn([]const u8, "source", files);
    const job_destinations = memory.borrowWriteColumn(u64, "destination", jobs);
    const indices = memory.borrowWriteColumn(u32, "index", jobs);
    const roots = memory.borrowWriteColumn(bool, "root", jobs);
    const variants = memory.borrowWriteColumn([]const []const u8, "variants", jobs);
    const comptime_entries = memory.borrowWriteColumn(bool, "comptime_entry", jobs);

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
        .jobs = plan.placement.jobs,
    };

    const input: Input = .{
        .files = &state,
        .members = plan.members,
        .scopes = plan.scopes,
        .placement = &counts,
        .jobs = &.{
            .destinations = @ptrCast(&job_destinations),
            .indices = @ptrCast(&indices),
            .roots = @ptrCast(&roots),
            .variants = @ptrCast(&variants),
            .comptime_entries = @ptrCast(&comptime_entries),
        },
    };

    generated.executeValue(allocator, &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.debug.panic("invalid partition placement: {s}", .{@errorName(err)}),
    };

    return .{ .files = files, .jobs = jobs };
}
