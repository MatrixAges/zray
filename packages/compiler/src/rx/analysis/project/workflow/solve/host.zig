const std = @import("std");
const zx = @import("zx");
const Derivation = @import("../derive/host.zig").State;
const Graph = @import("../../../inference/types.zig");
const SourceMap = @import("../../../source_map.zig");
const Constraints = @import("../../constraints.zig");
const Requests = @import("../../signatures/requests.zig");
const generated = @import("rx_options").generated_graph;
const Error = zx.Error;

pub fn run(derivation: *Derivation) Error!void {
    const backing = derivation.backing;

    const source_map = SourceMap.init(backing, derivation.sources) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        return derivation.fail(.{
            .path = derivation.entry,
            .location = if (derivation.entry_index) |row| derivation.sources[row].node.location else .{ .offset = 0, .line = 1, .column = 1 },
            .code = "unsupported",
            .message = "RX source positions exceed the supported address range",
        });
    };

    defer source_map.deinit(backing);

    var state: State = .{
        .derivation = derivation,
        .source_map = source_map,
        .workspace = .init(backing),
        .pending = .init(backing),
    };

    defer state.workspace.deinit();
    defer state.pending.deinit();
    defer state.resolver.deinit(backing);

    try state.execute();
}

pub const State = struct {
    derivation: *Derivation,
    source_map: SourceMap,
    workspace: zx.Arena,
    pending: zx.Arena,
    reporter: zx.Reporter = .{},
    graph: Graph = undefined,
    resolver: Graph.Resolver = .{},
    requests: Requests = .{},
    ports: Constraints.Ports = undefined,
    fn execute(self: *State) Error!void {
        if (comptime generated) {
            const entry = @import("generated_rx_project_solve");
            var empty = std.heap.FixedBufferAllocator.init(&.{});

            return entry.executeIn(empty.allocator(), @ptrCast(self));
        }

        try self.collect();
        try self.finish();
        try self.resolve();
    }
    pub fn collect(self: *State) Error!void {
        const derivation = self.derivation;
        const loaded = &derivation.prepared.?;

        self.graph = Graph.init(.{
            .graph = self.workspace.allocator(),
            .pending = self.pending.allocator(),
            .result = derivation.allocator,
            .backing = derivation.backing,
        }, &self.reporter, loaded.project.context.types) catch |err| return self.report(err);

        self.ports = Constraints.collect(&self.graph, loaded.modules, self.source_map, derivation.inputs, &self.requests) catch |err| return self.report(err);
    }

    pub fn finish(self: *State) Error!void {
        self.graph.finish(&self.resolver) catch |err| return self.report(err);

        self.graph.pending = undefined;

        self.pending.reset(0);
    }

    pub fn resolve(self: *State) Error!void {
        const derivation = self.derivation;
        const signatures = @import("../../signatures.zig");
        derivation.frame.resolved = signatures.resolve(&self.graph, &self.resolver, self.ports, self.requests) catch |err| return self.report(err);
        derivation.frame.types = self.graph.types.items.view();
    }
    fn report(self: *State, err: Error) Error {
        const project = @import("../../../project.zig");
        const value = try project.report(self.derivation.allocator, self.source_map, self.reporter, err);

        self.derivation.issue.* = value.diagnostic;

        return error.InvalidSource;
    }
};
