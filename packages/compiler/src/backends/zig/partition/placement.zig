const std = @import("std");
pub const File = struct { path: []const u8, source: []const u8 };

pub const Job = struct {
    destination: u64,
    index: u32,
    root: bool,
    variants: []const []const u8,
    comptime_entry: bool,
};

pub const Publication = struct { files: []File, jobs: []const Job };

pub fn materialize(temporary: std.mem.Allocator, placement: anytype, output: anytype) std.mem.Allocator.Error!Publication {
    const files = try temporary.alloc(File, @intCast(placement.length));

    errdefer temporary.free(files);

    const jobs = try temporary.alloc(Job, @intCast(placement.jobs));

    for (output.bodies, files[0..output.bodies.len]) |item, *slot| {
        slot.* = .{ .path = item.path, .source = item.source };
    }

    for (output.copies, files[output.bodies.len..][0..output.copies.len]) |item, *slot| {
        slot.* = .{ .path = item.path, .source = item.source };
    }

    const first_stub: usize = @intCast(placement.first_stub);

    for (output.stub_paths, files[first_stub..][0..output.stub_paths.len]) |path, *slot| {
        slot.path = path;
    }

    const first_root: usize = @intCast(placement.first_root);

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
