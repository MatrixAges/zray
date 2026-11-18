const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Route = enum { Boundary, Stable, Open, Declared };
const nesting_limit = 256;

const Step = struct {
    value: u32,
    root: Graph.Id,
    remaining: u64,
    route: Route = .Boundary,
};

pub fn guarded(graph: *Graph, source: Graph.Id, span: zx.Span) zx.Error!?Graph.Id {
    const step = walk(graph, source, 1);

    return switch (step.route) {
        .Open => null,
        .Stable, .Boundary => @fromBackingInt(step.value),
        .Declared => try graph.known(@fromBackingInt(step.value), span),
    };
}

pub fn hint(graph: *Graph, source: Graph.Id) zx.Error!?Graph.Id {
    var value = source;

    while (true) {
        const step = walk(graph, value, std.math.maxInt(u64));

        switch (step.route) {
            .Stable => return @fromBackingInt(step.value),
            .Open => return if (graph.nodes.items(.allowed)[@backingInt(step.root)] != null) @fromBackingInt(step.value) else null,
            .Declared => value = try register(graph, step),
            .Boundary => unreachable,
        }
    }
}

pub fn payload(graph: *Graph, source: Graph.Id) zx.Error!Graph.Id {
    var value = source;
    var remaining: u64 = nesting_limit;

    while (true) {
        const step = walk(graph, value, remaining);

        switch (step.route) {
            .Stable, .Open => return step.root,
            .Declared => {
                value = try register(graph, step);
                remaining = step.remaining;
            },
            .Boundary => {
                const root = graph.root(@fromBackingInt(step.value));

                return graph.reporter.fail(.unsupported, graph.nodes.items(.span)[@backingInt(root)], "type inference nesting exceeds 256 levels");
            },
        }
    }
}

fn register(graph: *Graph, step: Step) zx.Error!Graph.Id {
    return graph.known(@fromBackingInt(step.value), graph.nodes.items(.span)[@backingInt(step.root)]);
}

fn walk(graph: *const Graph, source: Graph.Id, remaining: u64) Step {
    var step: Step = .{ .value = @backingInt(source), .root = source, .remaining = remaining };

    while (step.remaining != 0) {
        step.root = graph.root(@fromBackingInt(step.value));

        switch (graph.shapeAt(@backingInt(step.root))) {
            .optional => |child| {
                step.value = @backingInt(child);
                step.remaining -= 1;
            },
            .known => |declared| {
                const value = graph.types.get(declared);

                if (value == .optional) {
                    step.value = @backingInt(value.optional);
                    step.remaining -= 1;
                    step.route = .Declared;
                } else {
                    step.route = .Stable;
                }

                return step;
            },
            .unknown => {
                step.route = .Open;

                return step;
            },
            else => {
                step.route = .Stable;

                return step;
            },
        }
    }

    return step;
}
