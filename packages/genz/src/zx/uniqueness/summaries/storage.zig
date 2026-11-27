const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Level = @import("../level.zig").Level;
const Summaries = @import("../summaries.zig");
const Basis = @import("../basis.zig");
const creating = @import("generated_uniqueness_prepare_program");
const lifecycle = @import("lifecycle.zig");
const Calls = @import("../topology.zig").Calls;
const Prepared = std.meta.Child(creating.Output);
const Cells = @FieldType(Prepared, "cells");

pub const Model = struct {
    layout: @FieldType(std.meta.Child(Cells), "layout"),
    guarantees: []u8,
    demands: []u8,
};

pub fn prepare(temporary: std.mem.Allocator, summary_memory: std.mem.Allocator, program: *const ir.Program, basis: *const Basis) std.mem.Allocator.Error!struct { calls: Calls, summaries: Summaries } {
    comptime {
        std.debug.assert(@sizeOf(Level) == @sizeOf(u8));
        std.debug.assert(@alignOf(Level) == @alignOf(u8));
    }

    const Input = std.meta.Child(creating.Input);
    const Bodies = std.meta.Child(@FieldType(Input, "bodies"));

    const input: Input = .{
        .bodies = &.{
            .expressions = zx.columns.slice(@FieldType(Bodies, "expressions"), program.functions.expressions),
            .native_modules = program.functions.native_modules,
            .entry = zx.columns.pointer(@FieldType(Bodies, "entry"), &program.expressions),
            .type_only = program.type_only,
        },
        .shape = &.{
            .counts = basis.slots.counts,
            .input_types = program.functions.input_types,
            .output_types = program.functions.output_types,
        },
    };

    const prepared = creating.executeIn(temporary, &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.debug.panic("ownership preparation failed: {s}", .{@errorName(err)}),
    };

    const prepared_layout = prepared.cells.layout;
    const guarantees = try summary_memory.dupe(u8, prepared.cells.guarantees);
    const demands = try summary_memory.dupe(u8, prepared.cells.demands);
    const layout = try summary_memory.create(std.meta.Child(@FieldType(std.meta.Child(Cells), "layout")));

    layout.* = .{
        .input_first = try summary_memory.dupe(u64, prepared_layout.input_first),
        .output_first = try summary_memory.dupe(u64, prepared_layout.output_first),
        .input_count = prepared_layout.input_count,
        .output_count = prepared_layout.output_count,
    };

    const model: Model = .{
        .layout = layout,
        .guarantees = guarantees,
        .demands = demands,
    };

    const input_rows = try sliceRows(summary_memory, layout.input_first, 0, layout.input_count, guarantees);
    const output_rows = try sliceRows(summary_memory, layout.output_first, layout.input_count, layout.output_count, guarantees);
    const input_wants = try sliceRows(summary_memory, layout.input_first, 0, layout.input_count, demands);
    const output_wants = try sliceRows(summary_memory, layout.output_first, layout.input_count, layout.output_count, demands);

    const result = Summaries{
        .input = input_rows,
        .output = output_rows,
        .inputs = input_wants,
        .outputs = output_wants,
        .held = basis.flow.held,
        .written = basis.flow.written,
        .return_only = basis.return_only,
        .effects = basis.effects,
        .storage = model,
    };

    const topology = prepared.topology;

    lifecycle.apply(result, .Initialize, topology.active, &.{});

    return .{
        .calls = .{ .active = topology.active, .callees = topology.callees, .recursive = topology.recursive },
        .summaries = result,
    };
}

fn sliceRows(allocator: std.mem.Allocator, first: []const u64, base: u64, count: u64, bytes: []u8) std.mem.Allocator.Error![][]Level {
    const result = try allocator.alloc([]Level, first.len);
    const levels: []Level = @ptrCast(bytes);

    for (result, 0..) |*slot, index| {
        const start = first[index];
        const end = if (index + 1 == first.len) count else first[index + 1];

        slot.* = levels[@intCast(base + start)..@intCast(base + end)];
    }

    return result;
}
