const std = @import("std");
const zx = @import("zx");
const Project = @import("../../project.zig").Project;
const Inputs = @import("../../module_input.zig");
const indexed = @import("../../parse_cache.zig").indexed_enabled;
const Phase = @import("../load/host.zig").Phase;
const errorSet = @import("invoke.zig").errorSet;
const Frame = @import("../../project.zig").LoadFrame;
const FrameHeader = @import("project_execution_abi").layouts.@"zig:project_host".ProjectFrameHeader;

pub const Header = union(enum) {
    native: zx.syntax.header.Native,
    indexed: if (indexed) @TypeOf(@as(Inputs.Indexed, undefined).header()) else void,
};

pub const Walk = struct {
    project: *Project,
    phase: Phase,
    paths: std.heap.ArenaAllocator,
    header: Header = undefined,
    frame_header: FrameHeader = undefined,
    fn borrow(handle: *anyopaque) *Walk {
        return @ptrCast(@alignCast(handle));
    }
    pub fn active(self: *Walk) *Frame {
        const frames = self.project.load_frames.items;

        return &frames[frames.len - 1];
    }
};

pub fn run(project: *Project, index: usize, phase: Phase) zx.Error!void {
    const entry = @import("generated_project_execute_load");
    const Input = std.meta.Child(entry.Input);
    var marks = std.mem.sliceAsBytes(project.load_states);
    var walk: Walk = .{ .project = project, .phase = phase, .paths = .init(project.arena.child_allocator) };

    defer walk.paths.deinit();

    const input: Input = .{
        .walk = @ptrCast(&walk),
        .frame = &.{ .states = marks, .marks = @ptrCast(&marks), .row = index, .depth = project.load_frames.items.len },
    };

    var arena = std.heap.ArenaAllocator.init(project.arena.child_allocator);

    defer arena.deinit();

    var buffer: [512]u8 = undefined;
    var fallback = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());
    const admission = zx.columns.invoke(entry.executeIn, fallback.allocator(), &input) catch |err| return errorSet(err);

    return switch (admission) {
        .Skip, .Push => {},
        .Cycle => project.dependencyCycle(),
        .Depth => project.dependencyDepth(),
    };
}

pub fn openProjectFrame(handle: *anyopaque, row: u64) zx.Error!void {
    const walk = Walk.borrow(handle);

    _ = walk.paths.reset(.free_all);

    try walk.project.pushFrame(@intCast(row));
}

pub fn readProjectFrame(handle: *anyopaque) *const FrameHeader {
    const walk = Walk.borrow(handle);
    const frame = walk.active();

    walk.project.current_source = frame.index;

    const count: u64 = switch (frame.parsed.result.*) {
        .native => |result| blk: {
            const input: Inputs.Native = .{ .value = result.value.parsed };
            const header = input.header();

            walk.header = .{ .native = header };

            break :blk header.importCount();
        },
        .indexed => |*result| if (indexed) blk: {
            const input: Inputs.Indexed = .{ .value = result };
            const header = input.header();

            walk.header = .{ .indexed = header };

            break :blk header.importCount();
        } else unreachable,
    };

    walk.frame_header = .{
        .count = count,
        .suspended = frame.suspended_import,
    };

    return &walk.frame_header;
}

pub fn resumeProjectImport(handle: *anyopaque, row: u64, child: u64) zx.Error!void {
    const walk = Walk.borrow(handle);

    _ = try @import("delivery/frame.zig").run(walk, @intCast(row), child);
}

pub fn visitProjectImport(handle: *anyopaque, row: u64) zx.Error!?u64 {
    return @import("delivery/frame.zig").run(Walk.borrow(handle), @intCast(row), null);
}

pub fn finishProjectFrame(handle: *anyopaque) zx.Error!void {
    const walk = Walk.borrow(handle);
    const frame = walk.active();

    _ = walk.paths.reset(.free_all);

    return switch (frame.parsed.result.*) {
        .native => |result| finish(walk, frame, Inputs.Native{ .value = result.value.parsed }),
        .indexed => |*result| if (indexed) finish(walk, frame, Inputs.Indexed{ .value = result }) else unreachable,
    };
}

fn finish(walk: *Walk, frame: *Frame, input: anytype) zx.Error!void {
    return switch (walk.phase) {
        .signature => walk.project.finishSignature(frame, input),
        .body => walk.project.finishInput(frame, input),
    };
}

pub fn closeProjectFrame(handle: *anyopaque) u64 {
    const walk = Walk.borrow(handle);
    const frames = &walk.project.load_frames;

    walk.active().deinitScratch(walk.project.arena.child_allocator);

    _ = frames.pop();

    return if (frames.items.len == 0) 0 else walk.active().index;
}
