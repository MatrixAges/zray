const std = @import("std");
const genz = @import("genz");
const ledger = @import("../output.zig");
const partition = @import("../partition.zig");
const layout = @import("../partition/build.zig");
const Bundle = @import("../library.zig").Bundle;
const File = @import("../partition/placement.zig").File;
const available = ledger.available;

pub fn write(io: std.Io, allocator: std.mem.Allocator, workspace: std.mem.Allocator, output: []const u8, bundle: Bundle, partitions: u32) !void {
    const groups = try ledger.inventory.group(allocator, bundle.modules);
    const tree = try ledger.assembly.prepare(allocator, &bundle, groups, partitions != 0);
    var scratch = std.heap.ArenaAllocator.init(workspace);

    defer scratch.deinit();

    const functions = functions: {
        var frame: Frame = .{
            .io = io,
            .allocator = allocator,
            .workspace = workspace,
            .scratch = scratch.allocator(),
            .bundle = &bundle,
            .tree = tree,
            .functions = groups.functions,
            .partitions = partitions,
        };

        if (comptime available) {
            const entry = @import("generated_bootstrap_tree");
            const input: std.meta.Child(entry.Input) = .{ .partitioned = partitions != 0 };
            const steps = try entry.executeIn(scratch.allocator(), &input);

            for (steps) |step| switch (step) {
                .Adapters => for (0..bundle.public_modules.len) |index| try frame.adapter(index),
                .Originals => try frame.originals(),
                .Root => try frame.root(false),
                .PartitionedRoot => try frame.root(true),
                .Place => try frame.place(),
            };
        } else {
            for (0..bundle.public_modules.len) |index| try frame.adapter(index);
            if (partitions != 0) try frame.originals();
            try frame.root(partitions != 0);
            if (partitions != 0) try frame.place();
        }

        break :functions frame.functions;
    };

    try @import("mirror.zig").write(io, allocator, workspace, output, .{ .head = tree.files, .functions = functions });
}

const Frame = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    workspace: std.mem.Allocator,
    scratch: std.mem.Allocator,
    bundle: *const Bundle,
    tree: ledger.assembly.Assembly,
    functions: []const File,
    partitions: u32,
    original: partition.layout.FunctionFiles = undefined,
    fn adapter(self: *const Frame, index: usize) !void {
        const module = &self.bundle.public_modules[index];

        self.tree.files[self.tree.sections.adapters + index].source = try genz.host.bootstrapReexports(self.allocator, self.workspace, .{
            .member = module.name,
            .value_entry = module.value_entry,
            .state_entry = module.state_entry,
            .allocator_entry = module.allocator_entry,
            .pending_entry = module.pending_entry,
            .constant_only = module.constant_only,
        });
    }
    fn originals(self: *Frame) !void {
        const slots = self.tree.sections;
        self.original = try ledger.inventory.originals(self.allocator, self.scratch, self.functions, self.tree.files[slots.originals..slots.original_root]);
        self.tree.files[slots.original_root].source = try partition.indexedRoot(self.allocator, self.workspace, self.original, null);
    }

    fn root(self: *const Frame, partitioned: bool) !void {
        self.tree.files[self.tree.sections.root].source = try partition.rootBacked(self.allocator, self.workspace, self.tree.modules, partitioned);
    }

    fn place(self: *Frame) !void {
        const slots = self.tree.sections;

        self.functions = try layout.plan(self.io, self.allocator, self.workspace, self.scratch, self.functions, self.original, self.tree.files[slots.support..slots.signatures], self.partitions);
    }
};
