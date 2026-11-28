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
            .frame = @ptrCast(&state),
            .ports = &stages.ports,
            .collection = &stages.collection.input,
            .solve = &stages.inference.input,
            .signatures = &stages.signatures.input,
        };

        const Store = std.meta.Child(@FieldType(abi.entry.zx_pending, "store_0"));

        var snapshot: std.meta.Child(Store) = .{
            .step = .RefreshBindings,
            .row = null,
            .left = null,
            .right = null,
            .diagnostic = null,
            .id = 0,
        };

        var store: Store = &snapshot;

        const Host = struct {
            frame: *Inference,
            snapshot: *std.meta.Child(Store),
            store_0: *Store,
            pub fn commit(host: *@This(), pending: anytype) Error!void {
                const effect = pending.store_0 orelse return;
                const frame = host.frame;

                switch (effect.step) {
                    .UnifyBinding => try frame.bindings.unify(@intCast(effect.row.?), effect.right.?),
                    .RefreshBindings => frame.bindings.refresh(),
                    .RejectBinding => return frame.bindings.reject(effect.diagnostic.?),
                    .MergeNonNull => try frame.non_null.merge(@intCast(effect.row.?), effect.left.?, effect.right.?),
                    .RefreshNonNull => frame.non_null.refresh(),
                    .ReserveNonNull => host.snapshot.id = try frame.non_null.reserve(@intCast(effect.row.?), effect.right.?),
                    .RegisterNonNull => host.snapshot.id = try frame.non_null.register(@intCast(effect.row.?), effect.right.?),
                }
            }
        };

        var host: Host = .{ .frame = &stages.inference, .snapshot = &snapshot, .store_0 = &store };

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

fn borrow(handle: *anyopaque) *State {
    return @ptrCast(@alignCast(handle));
}

pub fn openFlowPorts(handle: *anyopaque) Error!void {
    const state = borrow(handle);
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

pub fn commitFlowPorts(handle: *anyopaque, batches: []const *const PortBatch) Error!void {
    const state = borrow(handle);
    const stages = state.stages;

    try PortPublication.apply(&state.graph, state.ports, batches);

    stages.scope.active = stages.idle;

    stages.declarations.reset(0);
}

pub fn openFlowCollection(handle: *anyopaque) void {
    const state = borrow(handle);
    const stages = state.stages;

    stages.body.graph = &state.graph;
    stages.body.modules = state.derivation.prepared.?.modules;
    stages.body.states = state.ports;
    stages.scope.active = stages.collection_scratch.allocator();

    stages.collection.bind(&stages.body);
}

pub fn releaseFlowCollection(handle: *anyopaque) void {
    const stages = borrow(handle).stages;

    stages.scope.active = stages.idle;
    _ = stages.collection_scratch.reset(.free_all);
}

pub fn openFlowSolver(handle: *anyopaque) void {
    const state = borrow(handle);

    state.stages.inference.bind(&state.graph, &state.resolver, &state.stages.scope);
}

pub fn releaseFlowPending(handle: *anyopaque) void {
    const state = borrow(handle);
    const stages = state.stages;

    stages.scope.active = stages.idle;

    stages.inference.release();
    state.releasePending();
}

pub fn bindFlowSignatures(handle: *anyopaque) void {
    const state = borrow(handle);
    const stages = state.stages;
    const resolution = &stages.inference.resolution;
    const table = Signatures.borrow(state.ports, state.requests);

    stages.scope.active = stages.inference.workspace.allocator();

    resolution.bind(&state.graph, &state.resolver, &stages.scope);
    stages.signatures.bind(&state.graph, table, &resolution.view);
}

pub fn publishFlowSignatures(
    handle: *anyopaque,
    bindings: []const u32,
    tasks: []const u32,
    inputs: []const u32,
    outputs: []const u32,
) void {
    const state = borrow(handle);
    const stages = state.stages;
    const table = stages.signatures.table;
    const requests = &state.requests;
    const ports = state.ports;

    if (ports.len != 0) {
        @memcpy(@as([]u32, @ptrCast(requests.bindings.items(.value))), bindings);
        @memcpy(requests.tasks.items, tasks);
        @memcpy(@as([]u32, @ptrCast(ports.items(.input))), inputs);
        @memcpy(@as([]u32, @ptrCast(ports.items(.output))), outputs);
    }

    stages.scope.active = stages.idle;
    _ = stages.inference.workspace.reset(.free_all);

    state.publish(table);
}
