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
            var empty = std.heap.FixedBufferAllocator.init(&.{});

            return entry.executeIn(empty.allocator(), &.{ .state = @ptrCast(self), .row = 0, .count = self.modules.len }) catch |err| return prepare.loadError(err);
        }

        const handle: *const anyopaque = self;

        for (0..self.modules.len) |row| {
            try beginPreparedModule(handle, row);
            try prepareModuleStores(handle, row);
            try prepareModuleFlow(handle, row);
            try prepareModuleImports(handle, row);
            try publishPreparedModule(handle, row);
        }
    }

    inline fn borrow(handle: *const anyopaque) *const State {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn beginPreparedModule(handle: *const anyopaque, row: u64) std.mem.Allocator.Error!void {
    const self = State.borrow(handle);
    const loader = self.loader;
    const index: usize = @intCast(row);

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

pub fn prepareModuleStores(handle: *const anyopaque, row: u64) Error!void {
    const self = State.borrow(handle);
    const loader = self.loader;
    const index: usize = @intCast(row);
    loader.stores = try StoreReferences.resolve(loader.allocator, self.store_memory.allocator(), self.modules[index], loader.references.edges, loader.signatures.graph.sources, self.definitions, &loader.issue);
}

pub fn prepareModuleFlow(handle: *const anyopaque, row: u64) Error!void {
    const self = State.borrow(handle);
    const index: usize = @intCast(row);

    self.plans[index].plan = try self.loader.moduleBody(self.modules[index]);
}

pub fn prepareModuleImports(handle: *const anyopaque, row: u64) Error!void {
    const self = State.borrow(handle);
    const loader = self.loader;
    const index: usize = @intCast(row);
    const types = loader.project.context.types;
    const imports = try TypeImports.collect(loader.allocator, loader.allocator, self.modules[index], loader.references.edges, loader.signatures, types.kinds, &loader.issue);
    const plan = &self.plans[index];
    plan.type_imports = imports.types;
    plan.value_imports = imports.values;
}

pub fn publishPreparedModule(handle: *const anyopaque, row: u64) std.mem.Allocator.Error!void {
    const self = State.borrow(handle);
    const loader = self.loader;
    const index: usize = @intCast(row);

    try loader.inputs.publish(self.modules.len, index, loader.arguments.items);

    const plan = &self.plans[index];
    plan.source = self.modules[index];
    plan.deferred_shortcut = loader.deferred_shortcut;
    plan.calls = loader.calls.slice();
    self.local_calls[index] = loader.local_calls;
}
