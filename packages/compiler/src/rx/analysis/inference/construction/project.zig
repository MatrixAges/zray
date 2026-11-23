const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const projection = @import("projection/host.zig");
const ObjectClosure = @import("../object_closure.zig");
const Object = @import("../construction.zig").Object;
const generated = @import("generated_object_construction_resolve");
const Input = std.meta.Child(generated.Input);
const Parts = std.meta.Child(@FieldType(Input, "parts"));

pub fn propagate(graph: *Graph, closure: *ObjectClosure, object: Object, root: Graph.Id, final: bool) zx.Error!void {
    var arena = std.heap.ArenaAllocator.init(graph.scratch);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    defer arena.deinit();

    const allocator = scratch.allocator();
    var names: projection.NameSet = .empty;
    const parts = try projection.run(Parts, graph, closure, allocator, object, root, final, &names);

    if (names.count() == 0) return;

    const plan = generated.executeValue(allocator, &.{ .parts = &parts, .keys = @ptrCast(&names), .final = final }) catch |err| return failure(err);

    try @import("application/host.zig").run(graph, object, plan);
}

fn failure(err: anyerror) std.mem.Allocator.Error {
    return switch (err) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => error.OutOfMemory,
        else => unreachable,
    };
}
