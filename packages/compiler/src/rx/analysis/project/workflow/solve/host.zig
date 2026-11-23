const std = @import("std");
const zx = @import("zx");
const Derivation = @import("../derive/host.zig").State;
const Graph = @import("../../../inference/types.zig");
const SourceMap = @import("../../../source_map.zig");
const Constraints = @import("../../constraints.zig");
const Contracts = @import("../../contracts.zig");
const Ports = @import("../../constraints/ports.zig");
const PortHost = @import("../../constraints/ports/host.zig");
const Collection = @import("../../constraints/collection.zig");
const CollectionHost = @import("../../constraints/collection/host.zig");
const Inference = @import("../../../inference/solve/host.zig").Frame;
const Signatures = @import("../../signatures.zig");
const SignatureHost = @import("../../signatures/host.zig");
const Requests = @import("../../signatures/requests.zig");
const abi = @import("abi.zig");
const workflow = @import("../errors.zig");
const Error = zx.Error;
const generated = @import("rx_options").generated_graph;

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

    if (comptime generated) {
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        var stages: Stages = .{
            .empty = empty.allocator(),
            .scope = .{ .active = empty.allocator() },
            .declarations = .init(backing),
            .collection_scratch = .init(backing),
            .body = .{
                .graph = undefined,
                .modules = undefined,
                .source_map = source_map,
                .states = undefined,
                .arguments = derivation.inputs,
                .requests = &state.requests,
                .scope = .init(backing),
            },
            .inference = .{ .workspace = .init(backing), .closure = .init(backing) },
        };

        defer stages.deinit();

        state.stages = &stages;

        const input: abi.Input = .{
            .frame = @ptrCast(&state),
            .ports = &stages.ports.input,
            .collection = &stages.collection.input,
            .solve = &stages.inference.input,
            .signatures = &stages.signatures.input,
        };

        return abi.entry.executeIn(stages.scope.allocator(), &input) catch |err| state.report(switch (@as(anyerror, err)) {
            error.Overflow, error.IntegerOverflow => error.OutOfMemory,
            else => workflow.errorSet(err),
        });
    }

    state.seed() catch |err| return state.report(err);
}

const Stages = struct {
    empty: std.mem.Allocator,
    scope: zx.memory.ArenaScope,
    declarations: zx.Arena,
    ports: PortHost.Frame = .{},
    body: Collection,
    collection: CollectionHost.Frame = .{},
    collection_scratch: std.heap.ArenaAllocator,
    inference: Inference,
    signatures: SignatureHost.Frame = .{},
    fn deinit(self: *Stages) void {
        self.inference.deinit(&self.scope);
        self.collection_scratch.deinit();
        self.body.scope.deinit();
        self.declarations.deinit();
    }
};

const State = struct {
    derivation: *Derivation,
    source_map: SourceMap,
    workspace: zx.Arena,
    pending: zx.Arena,
    reporter: zx.Reporter = .{},
    graph: Graph = undefined,
    resolver: Graph.Resolver = .{},
    requests: Requests = .{},
    ports: Constraints.Ports = undefined,
    stages: if (generated) *Stages else void = undefined,
    fn openGraph(self: *State) Error!void {
        const derivation = self.derivation;
        const loaded = &derivation.prepared.?;

        self.graph = try Graph.init(.{
            .graph = self.workspace.allocator(),
            .pending = self.pending.allocator(),
            .result = derivation.allocator,
            .backing = derivation.backing,
        }, &self.reporter, loaded.project.context.types);
    }
    fn releasePending(self: *State) void {
        self.graph.pending = undefined;

        self.pending.reset(0);
    }

    fn publish(self: *State, table: Signatures.Table) void {
        const derivation = self.derivation;

        derivation.frame.resolved = table;
        derivation.frame.types = self.graph.types.items.view();
    }
    fn seed(self: *State) Error!void {
        const derivation = self.derivation;
        const loaded = &derivation.prepared.?;

        try self.openGraph();

        self.ports = try Constraints.collectSeed(&self.graph, loaded.modules, self.source_map, derivation.inputs, &self.requests);

        try self.graph.finishSeed(&self.resolver);

        self.releasePending();
        self.publish(try Signatures.resolveSeed(&self.graph, self.ports, self.requests));
    }

    fn report(self: *State, err: Error) Error {
        const project = @import("../../../project.zig");
        const value = try project.report(self.derivation.allocator, self.source_map, self.reporter, err);

        self.derivation.issue.* = value.diagnostic;

        return error.InvalidSource;
    }
};

fn borrow(handle: *const anyopaque) *State {
    return @ptrCast(@alignCast(@constCast(handle)));
}

pub fn openFlowPorts(handle: *const anyopaque) Error!void {
    const state = borrow(handle);
    const stages = state.stages;
    const modules = state.derivation.prepared.?.modules;

    try state.openGraph();

    state.ports = try Ports.reserve(state.graph.types.allocator, modules.len);

    const declared = try Contracts.resolve(stages.declarations.allocator(), &state.graph, modules, state.source_map);

    stages.ports.bind(&state.graph, state.ports, modules, state.source_map, declared);
}

pub fn releaseFlowDeclarations(handle: *const anyopaque) void {
    borrow(handle).stages.declarations.reset(0);
}

pub fn openFlowCollection(handle: *const anyopaque) void {
    const state = borrow(handle);
    const stages = state.stages;

    stages.body.graph = &state.graph;
    stages.body.modules = state.derivation.prepared.?.modules;
    stages.body.states = state.ports;
    stages.scope.active = stages.collection_scratch.allocator();

    stages.collection.bind(&stages.body, &stages.ports.port_columns);
}

pub fn releaseFlowCollection(handle: *const anyopaque) void {
    const stages = borrow(handle).stages;

    stages.scope.active = stages.empty;
    _ = stages.collection_scratch.reset(.free_all);
}

pub fn openFlowSolver(handle: *const anyopaque) void {
    const state = borrow(handle);

    state.stages.inference.bind(&state.graph, &state.resolver, &state.stages.scope);
}

pub fn releaseFlowPending(handle: *const anyopaque) void {
    const state = borrow(handle);
    const stages = state.stages;

    stages.scope.active = stages.empty;

    stages.inference.release();
    state.releasePending();
}

pub fn bindFlowSignatures(handle: *const anyopaque) void {
    const state = borrow(handle);
    const stages = state.stages;
    const resolution = &stages.inference.resolution;
    const table = Signatures.borrow(state.ports, state.requests);

    resolution.bind(&state.graph, &state.resolver, &stages.scope);
    stages.signatures.bind(&state.graph, table, &resolution.view);
}

pub fn publishFlowSignatures(handle: *const anyopaque) void {
    const state = borrow(handle);

    state.publish(state.stages.signatures.table);
}
