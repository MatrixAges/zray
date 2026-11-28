const std = @import("std");
const zx = @import("zx");
const Project = @import("../../project.zig").Project;
const Inputs = @import("../../module_input.zig");
const indexed = @import("../../parse_cache.zig").indexed_enabled;
const Phase = @import("../load/host.zig").Phase;
const errorSet = @import("invoke.zig").errorSet;
const Frame = @import("../../project.zig").LoadFrame;
const entry = @import("generated_project_execute_load");
const Input = std.meta.Child(entry.Input);
const Cursor = std.meta.Child(@typeInfo(@FieldType(Input, "walk")).optional.child);

pub const Header = union(enum) {
    native: zx.syntax.header.Native,
    indexed: if (indexed) @TypeOf(@as(Inputs.Indexed, undefined).header()) else void,
};

pub const Walk = struct {
    project: *Project,
    phase: Phase,
    paths: std.heap.ArenaAllocator,
    header: Header = undefined,
    pub fn active(self: *Walk) *Frame {
        const frames = self.project.load_frames.items;

        return &frames[frames.len - 1];
    }
};

pub fn run(project: *Project, index: usize, phase: Phase) zx.Error!void {
    var walk: Walk = .{ .project = project, .phase = phase, .paths = .init(project.arena.child_allocator) };

    defer walk.paths.deinit();

    const base = project.load_frames.items.len;

    const input: Input = .{
        .frame = &.{ .states = std.mem.sliceAsBytes(project.load_states), .row = index, .depth = base },
        .walk = null,
    };

    var arena = std.heap.ArenaAllocator.init(project.arena.child_allocator);

    defer arena.deinit();

    var buffer: [512]u8 = undefined;
    var fallback = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());
    const admitted = zx.columns.invoke(entry.executeIn, fallback.allocator(), &input) catch |err| return errorSet(err);

    switch (admitted.admission.?) {
        .Skip => return,
        .Cycle => return project.dependencyCycle(),
        .Depth => return project.dependencyDepth(),
        .Push => try open(&walk, index),
    }

    var completed: ?u64 = null;

    while (project.load_frames.items.len > base) {
        completed = try step(&walk, completed);
    }
}

fn step(walk: *Walk, completed: ?u64) zx.Error!?u64 {
    var cursor = read(walk, completed);
    const input: Input = .{ .frame = null, .walk = &cursor };
    var buffer: [512]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&buffer);
    const delivery = @import("delivery/frame.zig");

    while (true) {
        scratch.reset();

        const result = zx.columns.invoke(entry.executeIn, scratch.allocator(), &input) catch |err| return errorSet(err);
        const next = result.next.?;

        cursor.first = next.first;

        switch (next.action) {
            .Resume => {
                _ = try delivery.run(walk, @intCast(next.row.?), cursor.completed);
                cursor.completed = null;
            },
            .Visit => cursor.child = try delivery.run(walk, @intCast(next.row.?), null),
            .Push => {
                try open(walk, @intCast(next.row.?));

                return null;
            },
            .Close => {
                const returning = next.row;

                try finish(walk);

                close(walk);

                return returning;
            },
        }
    }
}

fn open(walk: *Walk, row: usize) zx.Error!void {
    walk.project.load_states[row] = .Visiting;
    _ = walk.paths.reset(.free_all);

    try walk.project.pushFrame(row);
}

fn read(walk: *Walk, completed: ?u64) Cursor {
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

    return .{
        .row = frame.index,
        .depth = walk.project.load_frames.items.len,
        .count = count,
        .suspended = frame.suspended_import,
        .first = 0,
        .completed = completed,
        .child = null,
    };
}

fn finish(walk: *Walk) zx.Error!void {
    const frame = walk.active();

    _ = walk.paths.reset(.free_all);

    return switch (frame.parsed.result.*) {
        .native => |result| finishInput(walk, frame, Inputs.Native{ .value = result.value.parsed }),
        .indexed => |*result| if (indexed) finishInput(walk, frame, Inputs.Indexed{ .value = result }) else unreachable,
    };
}

fn finishInput(walk: *Walk, frame: *Frame, input: anytype) zx.Error!void {
    return switch (walk.phase) {
        .signature => walk.project.finishSignature(frame, input),
        .body => walk.project.finishInput(frame, input),
    };
}

fn close(walk: *Walk) void {
    const frames = &walk.project.load_frames;
    const frame = walk.active();

    walk.project.load_states[frame.index] = .Done;

    frame.deinitScratch(walk.project.arena.child_allocator);

    _ = frames.pop();
}
