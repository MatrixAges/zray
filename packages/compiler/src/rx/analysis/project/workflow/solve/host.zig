const std = @import("std");
const zx = @import("zx");
const Derivation = @import("../derive/host.zig").State;
const Graph = @import("../../../inference/types.zig");
const SourceMap = @import("../../../source_map.zig");
const Constraints = @import("../../constraints.zig");
const Contracts = @import("../../contracts.zig");
const Ports = @import("../../constraints/ports.zig");
const PortPublication = @import("../../constraints/ports/publish.zig");
const PortBatch = @import("rx_execution_abi").layouts.@"zig:rx_project_host".PortBatch;
const Collection = @import("../../constraints/collection.zig");
const CollectionHost = @import("../../constraints/collection/host.zig");
const Projection = @import("../../../inference/projections/publish.zig");
const Inference = @import("../../../inference/solve/host.zig").Frame;
const Signatures = @import("../../signatures.zig");
const SignatureHost = @import("../../signatures/host.zig");
const Requests = @import("../../signatures/requests.zig");
const abi = @import("abi.zig");
const workflow = @import("../errors.zig");
const execution = @import("../execute.zig");
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
        var entry_scratch = std.heap.ArenaAllocator.init(backing);

        defer entry_scratch.deinit();

        const idle = entry_scratch.allocator();

        var stages: Stages = .{
            .idle = idle,
            .scope = .{ .active = idle },
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
            .ports = &stages.ports,
            .collection = &stages.collection.input,
            .solve = &stages.inference.input,
            .signatures = &stages.signatures.input,
        };

        const FlowSlot = comptime abi.slot("flow_step");
        const ReplaySlot = comptime abi.slot("step");
        const ProjectionSlot = comptime abi.slot("projection_step");
        const ObjectSlot = comptime abi.slot("object_step");
        const CollectionSlot = comptime abi.slot("collection_step");
        const ResolveSlot = comptime abi.slot("resolve_step");
        const Flow = std.meta.Child(abi.Store(FlowSlot));
        const Replay = std.meta.Child(abi.Store(ReplaySlot));
        const Projected = std.meta.Child(abi.Store(ProjectionSlot));
        const Object = std.meta.Child(abi.Store(ObjectSlot));
        const Collected = std.meta.Child(abi.Store(CollectionSlot));
        const Resolution = std.meta.Child(abi.Store(ResolveSlot));

        const flow_snapshot: Flow = .{
            .flow_step = .OpenPorts,
            .batches = &.{},
            .signatures = null,
        };

        var replay_snapshot = execution.snapshot(Replay, .{ .step = .RefreshBindings, .id = 0, .revision = 0, .remaining = 0 });
        var projection_snapshot = execution.snapshot(Projected, .{ .projection_step = .Merge, .id = 0 });
        var object_snapshot = execution.snapshot(Object, .{ .object_step = .FinishRow, .id = 0, .ready = false });

        var collection_snapshot = execution.snapshot(Collected, .{
            .collection_step = .Open,
            .shortcut = false,
            .input_fixed = false,
            .returned = false,
            .used = false,
            .bindings = 0,
            .tasks = 0,
            .parents = @as([]const u32, &.{}),
        });

        const resolution_snapshot = execution.snapshot(Resolution, .{ .resolve_step = .Record });
        var flow: abi.Store(FlowSlot) = &flow_snapshot;
        var replay: abi.Store(ReplaySlot) = &replay_snapshot;
        var projection: abi.Store(ProjectionSlot) = &projection_snapshot;
        var object: abi.Store(ObjectSlot) = &object_snapshot;
        var collection: abi.Store(CollectionSlot) = &collection_snapshot;
        var resolution: abi.Store(ResolveSlot) = &resolution_snapshot;

        const Host = struct {
            state: *State,
            replay_snapshot: *Replay,
            projection_snapshot: *Projected,
            object_snapshot: *Object,
            collection_snapshot: *Collected,
            store_0: *abi.Store("store_0") = undefined,
            store_1: *abi.Store("store_1") = undefined,
            store_2: *abi.Store("store_2") = undefined,
            store_3: *abi.Store("store_3") = undefined,
            store_4: *abi.Store("store_4") = undefined,
            store_5: *abi.Store("store_5") = undefined,
            pub fn commit(host: *@This(), pending: abi.entry.zx_pending) Error!void {
                const work = host.state;
                const current = work.stages;
                const frame = &current.inference;

                if (@field(pending, FlowSlot)) |effect| switch (effect.flow_step) {
                    .OpenPorts => try openFlowPorts(work),
                    .PublishPorts => try commitFlowPorts(work, zx.columns.slice([]const *const PortBatch, effect.batches)),
                    .OpenCollection => openFlowCollection(work),
                    .ReleaseCollection => releaseFlowCollection(work),
                    .OpenSolver => openFlowSolver(work),
                    .ReleasePending => releaseFlowPending(work),
                    .BindSignatures => bindFlowSignatures(work),
                    .PublishSignatures => publishFlowSignatures(work, effect.signatures.?),
                };

                if (@field(pending, ObjectSlot)) |effect| try frame.objects.commit(effect, host.object_snapshot);
                if (@field(pending, CollectionSlot)) |effect| try current.collection.commit(effect, host.collection_snapshot);
                if (@field(pending, ResolveSlot)) |effect| try @import("../../../inference/resolve/host.zig").commit(&frame.resolution, effect);
                if (@field(pending, ProjectionSlot)) |effect| try Projection.commit(frame.graph, null, effect, host.projection_snapshot);
                if (@field(pending, ReplaySlot)) |effect| try frame.replay(effect, host.replay_snapshot);
            }
        };

        var host: Host = .{
            .state = &state,
            .replay_snapshot = &replay_snapshot,
            .projection_snapshot = &projection_snapshot,
            .object_snapshot = &object_snapshot,
            .collection_snapshot = &collection_snapshot,
        };

        @field(host, FlowSlot) = &flow;
        @field(host, ReplaySlot) = &replay;
        @field(host, ProjectionSlot) = &projection;
        @field(host, ObjectSlot) = &object;
        @field(host, CollectionSlot) = &collection;
        @field(host, ResolveSlot) = &resolution;

        return abi.entry.executeIn(stages.scope.allocator(), &input, &host) catch |err| state.report(switch (@as(anyerror, err)) {
            error.Overflow, error.IntegerOverflow => error.OutOfMemory,
            else => workflow.errorSet(err),
        });
    }

    state.seed() catch |err| return state.report(err);
}

const Stages = struct {
    idle: std.mem.Allocator,
    scope: zx.memory.ArenaScope,
    declarations: zx.Arena,
    ports: abi.Ports = undefined,
    port_origins: std.meta.Child(@FieldType(abi.Ports, "origins")) = undefined,
    port_locations: zx.memory.ReadColumn = undefined,
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

fn openFlowPorts(state: *State) Error!void {
    const stages = state.stages;
    const modules = state.derivation.prepared.?.modules;

    try state.openGraph();

    state.ports = try Ports.reserve(state.graph.types.allocator, modules.len);

    const declared = try Contracts.resolve(stages.declarations.allocator(), &state.graph, modules, state.source_map);

    stages.scope.active = stages.declarations.allocator();
    stages.port_locations = zx.memory.borrowNestedColumn(usize, &.{ "source", "node", "location", "offset" }, modules);
    stages.port_origins = .{ .ends = state.source_map.ends, .locations = @ptrCast(&stages.port_locations) };

    stages.ports = .{
        .owners = declared.owners,
        .types = @ptrCast(declared.types),
        .modules = modules.len,
        .origins = &stages.port_origins,
    };
}

fn commitFlowPorts(state: *State, batches: []const *const PortBatch) Error!void {
    const stages = state.stages;

    try PortPublication.apply(&state.graph, state.ports, batches);

    stages.scope.active = stages.idle;

    stages.declarations.reset(0);
}

fn openFlowCollection(state: *State) void {
    const stages = state.stages;

    stages.body.graph = &state.graph;
    stages.body.modules = state.derivation.prepared.?.modules;
    stages.body.states = state.ports;
    stages.scope.active = stages.collection_scratch.allocator();

    stages.collection.bind(&stages.body);
}

fn releaseFlowCollection(state: *State) void {
    const stages = state.stages;

    stages.scope.active = stages.idle;
    _ = stages.collection_scratch.reset(.free_all);
}

fn openFlowSolver(state: *State) void {
    state.stages.inference.bind(&state.graph, &state.resolver, &state.stages.scope);
}

fn releaseFlowPending(state: *State) void {
    const stages = state.stages;

    stages.scope.active = stages.idle;

    stages.inference.release();
    state.releasePending();
}

fn bindFlowSignatures(state: *State) void {
    const stages = state.stages;
    const resolution = &stages.inference.resolution;
    const table = Signatures.borrow(state.ports, state.requests);

    stages.scope.active = stages.inference.workspace.allocator();

    resolution.bind(&state.graph, &state.resolver, &stages.scope);
    stages.signatures.bind(&state.graph, table, &resolution.view);
}

fn publishFlowSignatures(state: *State, signatures: anytype) void {
    const stages = state.stages;
    const table = stages.signatures.table;
    const requests = &state.requests;
    const ports = state.ports;

    if (ports.len != 0) {
        @memcpy(@as([]u32, @ptrCast(requests.bindings.items(.value))), signatures.bindings);
        @memcpy(requests.tasks.items, signatures.tasks);
        @memcpy(@as([]u32, @ptrCast(ports.items(.input))), signatures.inputs);
        @memcpy(@as([]u32, @ptrCast(ports.items(.output))), signatures.outputs);
    }

    stages.scope.active = stages.idle;
    _ = stages.inference.workspace.reset(.free_all);

    state.publish(table);
}
