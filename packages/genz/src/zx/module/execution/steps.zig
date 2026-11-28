const std = @import("std");
const Frame = @import("frame.zig");
const emission = @import("emission.zig");
const requests = @import("requests.zig");
const functions = @import("function.zig");
const Stored = @import("../../../node/stored.zig").Declarations;
const failure = @import("../../construction/publication.zig").failure;
const Error = std.mem.Allocator.Error;

pub fn execute(comptime entry: type, frame: *Frame, input: std.meta.Child(entry.Input)) Error!Stored {
    var scratch = std.heap.ArenaAllocator.init(frame.lowering.workspace);
    var buffer: [512]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const allocator = memory.allocator();
    const plan = entry.executeIn(allocator, &input) catch |err| return failure(err);

    for (plan.steps) |step| switch (step) {
        .Standard => try emission.emitModuleStandard(frame),
        .Imports => try emission.emitModuleImports(frame),
        .Types => try emission.emitModuleTypes(frame),
        .Exports => try emission.emitModuleExports(frame),
        .Constants => try emission.emitModuleConstants(frame),
        .Shape => try emission.emitModuleShape(frame),
        .Aliases => try emission.emitModuleAliases(frame),
        .Store => try emission.emitModuleStore(frame),
        .Entry => try emission.emitModuleEntry(frame),
        .ValueEntry => try emission.emitModuleValueEntry(frame),
        .Requests => if (comptime @hasField(@TypeOf(input), "request")) try drain(entry, allocator, frame, input) else unreachable,
        .Suffix => try appendSuffix(entry, allocator, frame, input),
        .Auxiliary => try frame.appendModuleAuxiliary(),
        .AppendSuffix => try frame.appendModuleSuffix(),
        .Finish => try frame.finishModuleDeclarations(),
        .OpenFunction => try functions.openFunctionModule(frame),
        .OpenNative => functions.openNativeFunctionModule(frame),
        .NativeBody => try functions.emitFunctionModuleBody(frame, .Native),
        .RegularBody => try functions.emitFunctionModuleBody(frame, .Regular),
        .ValueBody => try functions.emitFunctionModuleBody(frame, .Value),
        else => unreachable,
    };

    return frame.result;
}

fn drain(comptime entry: type, allocator: std.mem.Allocator, frame: *Frame, original: std.meta.Child(entry.Input)) Error!void {
    var input = original;

    while (true) {
        const form = requests.takeModuleFunction(frame);

        input.request = @fromBackingInt(@backingInt(form));
        const plan = entry.executeIn(allocator, &input) catch |err| return failure(err);

        if (plan.steps.len == 0) return;

        for (plan.steps) |step| switch (step) {
            .RequestedNative => try requests.emitRequestedNative(frame),
            .RequestedOpen => try requests.openRequestedFunction(frame),
            .RequestedStore => try requests.emitRequestedStore(frame),
            .RequestedRegular => try requests.emitRequestedBody(frame, false),
            .RequestedValue => try requests.emitRequestedBody(frame, true),
            .RequestedPublish => requests.publishRequestedFunction(frame),
            else => unreachable,
        };
    }
}

fn appendSuffix(comptime entry: type, allocator: std.mem.Allocator, frame: *Frame, original: std.meta.Child(entry.Input)) Error!void {
    var input = original;

    input.suffix = &.{ .uses_parallel = frame.lowering.uses_parallel, .comparisons = frame.comparisons.items.len };
    const plan = entry.executeIn(allocator, &input) catch |err| return failure(err);

    for (plan.steps) |step| switch (step) {
        .ParallelAllocator => try emission.emitModuleParallelAllocator(frame),
        .Comparisons => for (0..@as(usize, @intCast(plan.comparisons))) |row| try emission.emitModuleComparison(frame, row),
        else => unreachable,
    };
}
