const std = @import("std");
const zx = @import("zx");
const Library = @import("../../library/root.zig").Result;
const Batch = @import("batch.zig");
const PublicModule = @import("library.zig").PublicModule;
const Plan = @import("library_publication.zig").Plan;
const Error = std.mem.Allocator.Error || error{InvalidModule};
const references = @import("genz").zx.references;

pub const Published = struct {
    modules: []PublicModule,
    batches: []Batch,
    roots: []*const zx.ir.Program,
};

const Frame = struct {
    owned: std.mem.Allocator,
    library: *const Library,
    batch: *const Batch,
    plan: Plan,
    file_imports: bool,
    published: Published,
};

pub fn create(owned: std.mem.Allocator, workspace: std.mem.Allocator, library: *const Library, batch: *const Batch, plan: Plan, file_imports: bool) Error!Published {
    const count = library.exports.len;

    const frame: Frame = .{
        .owned = owned,
        .library = library,
        .batch = batch,
        .plan = plan,
        .file_imports = file_imports,
        .published = .{
            .modules = try owned.alloc(PublicModule, count),
            .batches = try workspace.alloc(Batch, count),
            .roots = try workspace.alloc(*const zx.ir.Program, count),
        },
    };

    if (comptime @import("parser_options").generated_parser) {
        const rule = @import("generated_library_publish_entries");
        var scratch = std.heap.FixedBufferAllocator.init(&.{});

        for (0..plan.ends.len) |index| {
            const input: std.meta.Child(rule.Input) = .{ .ends = plan.ends, .index = index };
            const range = zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch unreachable;

            try analyze(&frame, index, @intCast(range.first), @intCast(range.end));
            try publish(&frame, index, @intCast(range.first), @intCast(range.end));
        }
    } else {
        var first: usize = 0;

        for (plan.ends, 0..) |end, index| {
            try analyze(&frame, index, first, @intCast(end));
            try publish(&frame, index, first, @intCast(end));

            first = @intCast(end);
        }
    }

    return frame.published;
}

fn analyze(frame: *const Frame, index: usize, first: usize, end: usize) Error!void {
    const view = if (frame.file_imports)
        try @import("library_entry.zig").create(frame.owned, frame.library, index)
    else
        try frame.library.module(index);

    const batch = &frame.published.batches[index];
    batch.* = frame.batch.*;
    batch.program = view;
    batch.public_members = frame.plan.members[first..end];

    try batch.analysis.value.reentry(frame.owned, batch.backing, view);
}

fn publish(frame: *const Frame, index: usize, first: usize, end: usize) std.mem.Allocator.Error!void {
    const batch = &frame.published.batches[index];
    const program = &batch.program;
    const imports = try references.imports(frame.owned, batch.backing, program.expressions, program.contracts, batch.names.functions, frame.plan.member_ids[first..end]);
    const identity = try @import("publication/identity.zig").create(frame.owned, .Public, frame.library.exports[index].name);
    const analysis = &batch.analysis.value;

    frame.published.modules[index] = .{
        .name = identity.identity,
        .value_entry = analysis.hasValueEntry(),
        .state_entry = analysis.hasStateEntry(program.*),
        .allocator_entry = analysis.hasAllocatorEntry(),
        .pending_entry = program.stores.count() > 0,
        .requires_io = analysis.entry_flags.io,
        .requires_process = analysis.entry_flags.process,
        .file = .{ .name = identity.module, .source = &.{}, .imports = imports },
    };

    frame.published.roots[index] = program;
}
