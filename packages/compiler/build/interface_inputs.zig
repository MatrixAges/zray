const std = @import("std");
const compiler = @import("compiler");
const plan = compiler.source_inputs.interfaces;
const Resident = @import("resident/state.zig");
const Interface = @import("generation_manifest.zig").Interface;

const Result = struct {
    bindings: []const compiler.project.NativeInterface,
    external: usize,
    failure: ?anyerror,
};

pub fn load(io: std.Io, scratch: std.mem.Allocator, owned: std.mem.Allocator, resident: *Resident, declarations: []const Interface, sources: []const compiler.project.Source) !Result {
    const jobs = try scratch.alloc(plan.Job, declarations.len);
    const external = try plan.register(scratch, declarations, sources, jobs);
    const bindings = try owned.alloc(compiler.project.NativeInterface, declarations.len);
    var failure: ?anyerror = null;

    for (declarations, jobs) |entry, job| {
        const source = if (plan.sourceRow(job.source)) |row|
            sources[row].source

        else
            resident.files.read(io, .cwd(), entry.path, try std.fs.path.resolve(scratch, &.{entry.path}), true) catch |err| unread: {
                if (failure == null) failure = err;

                break :unread "";
            };

        bindings[@intCast(job.binding)] = .{
            .specifier = try resident.retainText(owned, job.name),
            .path = try resident.retainText(owned, entry.path),
            .source = source,
            .namespace = if (entry.resolve_members == true) &.{compiler.native_lookup.marker} else &.{},
            .module = try resident.retainText(owned, entry.module),
        };
    }

    return .{ .bindings = bindings, .external = external, .failure = failure };
}
