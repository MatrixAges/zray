const std = @import("std");
const builtin = @import("builtin");
const Inputs = @import("../cli/watch/inputs.zig");
const source = @import("manifest/input.zig");
const workspace = @import("workspace.zig");
const decision = @import("cli_source").workspace_discovery_decision;

pub const Result = struct {
    path: ?[]const u8 = null,
    root: ?source.Known = null,
    members: ?workspace.Result = null,
    diagnostic: ?[]const u8 = null,
    pub fn deinit(self: *Result) void {
        if (self.members) |*members| members.deinit();
    }
};

const Nearest = struct { manifest: source.Known, arena: std.heap.ArenaAllocator };

/// The compilation allocator owns the accepted manifests. The workspace result owns only the walk metadata.
pub fn findWithInputs(io: std.Io, scratch: std.mem.Allocator, retained: std.mem.Allocator, entry: []const u8, inputs: ?*Inputs) !Result {
    if (inputs) |observed| try observed.add(io, entry);

    const real = try std.Io.Dir.cwd().realPathFileAlloc(io, entry, scratch);
    var directory = std.fs.path.dirname(real).?;
    var nearest: ?Nearest = null;
    var retain_nearest = false;

    defer if (!retain_nearest) {
        if (nearest) |saved| saved.arena.deinit();
    };

    while (true) {
        const path = try std.fs.path.join(scratch, &.{ directory, "pkg.yaml" });

        const file = source.locate(io, scratch, path, inputs) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };

        if (file) |found| {
            var arena = std.heap.ArenaAllocator.init(retained);
            var keep = false;

            defer if (!keep) arena.deinit();

            const parsed = source.decode(io, arena.allocator(), found, inputs) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };

            if (parsed) |value| {
                const data = switch (value) {
                    .data => |data| data,
                    .diagnostic => |issue| return .{ .diagnostic = try source.diagnostic(scratch, path, issue) },
                };

                const candidate: source.Known = .{ .file = found, .data = data };
                var empty = std.heap.FixedBufferAllocator.init(&.{});

                switch (decision.executeValue(empty.allocator(), &.{
                    .has_nearest = nearest != null,
                    .has_workspace = data.workspace != null,
                }) catch unreachable) {
                    .Remember => {
                        nearest = .{ .manifest = candidate, .arena = arena };
                        keep = true;
                    },
                    .Select => {
                        keep = true;

                        return .{ .path = path, .root = candidate };
                    },
                    .Inspect => {
                        var member_memory = std.heap.ArenaAllocator.init(retained);
                        var selected = false;

                        defer if (!selected) member_memory.deinit();

                        const local = nearest.?.manifest;

                        var members = try workspace.loadPrepared(io, std.heap.smp_allocator, .{
                            .path = path,
                            .inputs = inputs,
                            .manifests = member_memory.allocator(),
                            .root = candidate,
                            .member = local,
                        });

                        defer if (!selected) members.deinit();

                        if (members.diagnostic) |message| return .{ .diagnostic = try scratch.dupe(u8, message) };

                        const target = try std.fs.path.relative(scratch, directory, null, directory, std.fs.path.dirname(local.file.path).?);
                        const member = if (comptime builtin.os.tag == .windows) try workspace.portablePath(scratch, target) else target;

                        if (workspace.containsMember(members.packages, member)) {
                            selected = true;
                            keep = true;
                            retain_nearest = true;

                            return .{ .path = path, .members = members };
                        }
                    },
                    .Continue => {},
                }
            }
        }

        directory = std.fs.path.dirname(directory) orelse break;
    }

    if (nearest) |saved| {
        retain_nearest = true;

        return .{ .path = saved.manifest.file.path, .root = saved.manifest };
    }

    return .{};
}
