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
    const state: State = .{ .paths = paths, .bodies = @ptrCast(&bodies) };

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
    };

    const output = generated.executeValue(allocator, &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.debug.panic("invalid partition placement: {s}", .{@errorName(err)}),
    };

    for (output.bodies, files[0..output.bodies.len]) |item, *slot| {
        slot.* = .{ .path = item.path, .source = item.source };
    }

    for (output.copies, files[output.bodies.len..][0..output.copies.len]) |item, *slot| {
        slot.* = .{ .path = item.path, .source = item.source };
    }

    const first_stub: usize = @intCast(plan.placement.first_stub);

    for (output.stub_paths, files[first_stub..][0..output.stub_paths.len]) |path, *slot| {
        slot.path = path;
    }

    const first_root: usize = @intCast(plan.placement.first_root);

    for (output.root_paths, files[first_root..][0..output.root_paths.len]) |path, *slot| {
        slot.path = path;
    }

    for (output.stub_jobs, jobs[0..output.stub_jobs.len]) |item, *slot| {
        slot.* = .{
            .destination = item.destination,
            .index = item.index,
            .root = item.root,
            .variants = item.variants,
            .comptime_entry = item.comptime_entry,
        };
    }

    for (output.root_jobs, jobs[output.stub_jobs.len..][0..output.root_jobs.len]) |item, *slot| {
        slot.* = .{
            .destination = item.destination,
            .index = item.index,
            .root = item.root,
            .variants = item.variants,
            .comptime_entry = item.comptime_entry,
        };
    }

    return .{ .files = files, .jobs = jobs };
}
