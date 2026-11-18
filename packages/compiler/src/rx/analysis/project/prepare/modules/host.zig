const std = @import("std");
const rx = @import("rx");
const prepare = @import("../../prepare.zig");
const Flow = @import("../../flow.zig");
const Graph = @import("../../source_graph/model.zig");
const TypeImports = @import("../../type_imports.zig");
const Store = @import("../../../store.zig");
const StoreReferences = @import("../../../store/references.zig");
const generated = @import("rx_options").generated_graph;
const Error = prepare.Loader.Error;

pub const State = struct {
    loader: *prepare.Loader,
    store_memory: *std.heap.ArenaAllocator,
    modules: []const rx.ModuleSource,
    registered: []const []const Graph.Edge,
    definitions: []const Store.Definition,
    plans: []prepare.Module,
    local_calls: []bool,
    row: usize = 0,
    flow: Flow.Plan = .{},
    imports: TypeImports.Imports = .{},
    pub fn load(self: *State) Error!void {
        std.debug.assert(self.modules.len == self.registered.len);

        if (comptime generated) {
            const entry = @import("generated_rx_prepare_modules");
            const Input = std.meta.Child(entry.Input);
            const input: Input = .{ .context = @ptrCast(self), .count = self.modules.len };
            var empty = std.heap.FixedBufferAllocator.init(&.{});

            return entry.executeIn(empty.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidFlow => error.InvalidFlow,
                else => unreachable,
            };
        }

        for (0..self.modules.len) |row| {
            try self.begin(row);
            try self.stores();
            try self.body();
            try self.types();
            try self.publish();
        }
    }
    pub fn begin(self: *State, row: usize) Error!void {
        if (self.definitions.len != 0 and !self.store_memory.reset(.retain_capacity)) return error.OutOfMemory;

        const loader = self.loader;

        self.row = row;
        loader.owner = self.modules[row].path;
        loader.references = .{ .edges = self.registered[row] };
        loader.calls = .empty;
        loader.local_calls = true;
        loader.arguments = .empty;
        loader.plan = .{};
        loader.task_count = 0;
        loader.deferred_shortcut = false;
    }

    pub fn stores(self: *State) Error!void {
        const loader = self.loader;
        const result = try StoreReferences.resolve(loader.allocator, self.store_memory.allocator(), self.modules[self.row], self.registered[self.row], loader.signatures.graph.sources, self.definitions);

        if (result == .diagnostic) {
            loader.issue = result.diagnostic;

            return error.InvalidFlow;
        }

        loader.stores = result.scope;
    }

    pub fn body(self: *State) Error!void {
        self.flow = try self.loader.moduleBody(self.modules[self.row]);
    }

    pub fn types(self: *State) Error!void {
        const loader = self.loader;
        const result = try TypeImports.collect(loader.allocator, loader.allocator, self.modules[self.row], self.registered[self.row], loader.signatures, loader.project.context.types.kinds);

        if (result == .diagnostic) {
            loader.issue = result.diagnostic;

            return error.InvalidFlow;
        }

        self.imports = result.imports;
    }

    pub fn publish(self: *State) Error!void {
        const loader = self.loader;
        const row = self.row;
        const imports = self.imports;

        try loader.inputs.publish(self.modules.len, row, loader.arguments.items);

        self.plans[row] = .{
            .source = self.modules[row],
            .deferred_shortcut = loader.deferred_shortcut,
            .calls = loader.calls.slice(),
            .plan = self.flow,
            .type_imports = imports.types,
            .value_imports = imports.values,
        };

        self.local_calls[row] = loader.local_calls;
    }
};
