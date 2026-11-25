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

pub const Model = struct {
    layout: @FieldType(Prepared, "layout"),
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
    var scope = zx.memory.ArenaScope{ .active = temporary };
    var input_rows: zx.memory.RowBuffer = .empty([]Level);
    var output_rows: zx.memory.RowBuffer = .empty([]Level);
    var input_wants: zx.memory.RowBuffer = .empty([]Level);
    var output_wants: zx.memory.RowBuffer = .empty([]Level);
    var guarantees: []u8 = &.{};
    var demands: []u8 = &.{};

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
        .views = &.{
            .input = @ptrCast(&input_rows),
            .output = @ptrCast(&output_rows),
            .inputs = @ptrCast(&input_wants),
            .outputs = @ptrCast(&output_wants),
        },
        .buffers = &.{
            .guarantees = @ptrCast(&guarantees),
            .demands = @ptrCast(&demands),
        },
        .arenas = &.{
            .scope = @ptrCast(&scope),
            .temporary = @ptrCast(&temporary),
            .summaries = @ptrCast(&summary_memory),
        },
    };

    const prepared = creating.executeIn(scope.allocator(), &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.debug.panic("ownership preparation failed: {s}", .{@errorName(err)}),
    };

    const model: Model = .{
        .layout = prepared.layout,
        .guarantees = guarantees,
        .demands = demands,
    };

    const result = Summaries{
        .input = input_rows.rows([]Level),
        .output = output_rows.rows([]Level),
        .inputs = input_wants.rows([]Level),
        .outputs = output_wants.rows([]Level),
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
