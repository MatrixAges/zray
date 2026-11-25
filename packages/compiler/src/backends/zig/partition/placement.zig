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
    var target = memory.borrowWriteFields(.{ .target_paths = "path", .target_sources = "source" }, files);

    var publications = memory.borrowWriteFields(.{
        .destinations = "destination",
        .indices = "index",
        .roots = "root",
        .variants = "variants",
        .comptime_entries = "comptime_entry",
    }, jobs);

    var state: State = undefined;

    target.fill(&state);

    state.paths = paths;
    state.bodies = @ptrCast(&bodies);

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
        .jobs = &publications.bind(std.meta.Child(@FieldType(Input, "jobs"))),
    };

    generated.executeValue(allocator, &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.debug.panic("invalid partition placement: {s}", .{@errorName(err)}),
    };

    return .{ .files = files, .jobs = jobs };
}
