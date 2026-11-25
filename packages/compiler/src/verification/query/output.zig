const std = @import("std");
const zx = @import("zx");
const Graph = @import("../graph.zig");
const Conditions = @import("../conditions.zig");
const Allocator = std.mem.Allocator;
const layout = @import("generated_verification_query");
const Request = @typeInfo(@TypeOf(layout.executeValue)).@"fn".param_types[1].?;
const Input = if (@typeInfo(Request) == .pointer) std.meta.Child(Request) else Request;

pub fn render(result: Allocator, temporary: Allocator, graph: *Graph, precondition_count: usize, input: Input, inputs: []const Conditions.Input) zx.Error!Conditions.Query {
    var scratch = std.heap.ArenaAllocator.init(temporary);

    defer scratch.deinit();

    const sections = try layout.executeValue(scratch.allocator(), if (Input == Request) input else &input);

    return @import("assembly.zig").write(result, graph, precondition_count, sections, inputs);
}
