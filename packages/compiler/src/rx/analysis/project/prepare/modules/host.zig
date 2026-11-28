const std = @import("std");
const rx = @import("rx");
const prepare = @import("../../prepare.zig");
const Graph = @import("../../source_graph/model.zig");
const TypeImports = @import("../../type_imports.zig");
const Store = @import("../../../store.zig");
const StoreReferences = @import("../../../store/references.zig");
const Error = prepare.Loader.Error;
const generated = @import("rx_options").generated_graph;

pub const State = struct {
    loader: *prepare.Loader,
    store_memory: *std.heap.ArenaAllocator,
    modules: []const rx.ModuleSource,
    registered: []const []const Graph.Edge,
    definitions: []const Store.Definition,
    plans: []prepare.Module,
    local_calls: []bool,
    pub fn load(self: *const State) Error!void {
        if (comptime generated) {
            const entry = @import("generated_rx_prepare_modules");
            const Command = std.meta.Child(@FieldType(entry.zx_pending, "store_0"));

            const Host = struct {
                state: *const State,
                store_0: *Command,
                pub fn commit(host: *@This(), pending: entry.zx_pending) Error!void {
                    const command = pending.store_0 orelse return;
                    const row: usize = @intCast(command.row);

                    switch (command.step) {
                        .Begin => try beginPreparedModule(host.state, row),
                        .Stores => try prepareModuleStores(host.state, row),
                        .Flow => try prepareModuleFlow(host.state, row),
                        .Imports => try prepareModuleImports(host.state, row),
                        .Publish => try publishPreparedModule(host.state, row),
                    }
                }
            };

            const initial: std.meta.Child(Command) = .{ .step = .Begin, .row = 0 };
            var command: Command = &initial;
            var host: Host = .{ .state = self, .store_0 = &command };
            var arena = std.heap.ArenaAllocator.init(self.store_memory.child_allocator);

            defer arena.deinit();

            var buffer: [512]u8 = undefined;
            var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

            return entry.executeIn(scratch.allocator(), &.{
                .row = 0,
                .count = self.modules.len,
            }, &host) catch |err| return prepare.loadError(err);
        }

        for (0..self.modules.len) |row| {
            try beginPreparedModule(self, row);
            try prepareModuleStores(self, row);
            try prepareModuleFlow(self, row);
            try prepareModuleImports(self, row);
            try publishPreparedModule(self, row);
        }
    }
};

fn beginPreparedModule(self: *const State, index: usize) std.mem.Allocator.Error!void {
    const loader = self.loader;

    if (self.definitions.len != 0 and !self.store_memory.reset(.retain_capacity)) return error.OutOfMemory;

    loader.owner = self.modules[index].path;
    loader.references = .{ .edges = self.registered[index] };
    loader.calls = .empty;
    loader.local_calls = true;
    loader.arguments = .empty;
    loader.plan = .{};
    loader.task_count = 0;
    loader.deferred_shortcut = false;
}

fn prepareModuleStores(self: *const State, index: usize) Error!void {
    const loader = self.loader;

    loader.stores = try StoreReferences.resolve(loader.allocator, self.store_memory.allocator(), self.modules[index], loader.references.edges, loader.signatures.graph.sources, self.definitions, &loader.issue);
}

fn prepareModuleFlow(self: *const State, index: usize) Error!void {
    self.plans[index].plan = try self.loader.moduleBody(self.modules[index]);
}

fn prepareModuleImports(self: *const State, index: usize) Error!void {
    const loader = self.loader;
    const types = loader.project.context.types;
    const imports = try TypeImports.collect(loader.allocator, loader.allocator, self.modules[index], loader.references.edges, loader.signatures, types.kinds, &loader.issue);
    const plan = &self.plans[index];
    plan.type_imports = imports.types;
    plan.value_imports = imports.values;
}

fn publishPreparedModule(self: *const State, index: usize) std.mem.Allocator.Error!void {
    const loader = self.loader;

    try loader.inputs.publish(self.modules.len, index, loader.arguments.items);

    const plan = &self.plans[index];
    plan.source = self.modules[index];
    plan.deferred_shortcut = loader.deferred_shortcut;
    plan.calls = loader.calls.slice();
    self.local_calls[index] = loader.local_calls;
}
