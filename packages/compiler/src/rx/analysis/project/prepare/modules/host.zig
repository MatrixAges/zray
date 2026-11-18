const std = @import("std");
const rx = @import("rx");
const prepare = @import("../../prepare.zig");
const Flow = @import("../../flow.zig");
const Graph = @import("../../source_graph/model.zig");
const TypeImports = @import("../../type_imports.zig");
const Store = @import("../../../store.zig");
const StoreReferences = @import("../../../store/references.zig");
const schedule = @import("../schedule.zig");
const Error = prepare.Loader.Error;

pub const State = struct {
    loader: *prepare.Loader,
    store_memory: *std.heap.ArenaAllocator,
    modules: []const rx.ModuleSource,
    registered: []const []const Graph.Edge,
    definitions: []const Store.Definition,
    plans: []prepare.Module,
    local_calls: []bool,
    pub fn load(self: *const State) Error!void {
        const loader = self.loader;

        for (self.modules, self.registered, self.plans, self.local_calls, 0..) |source, edges, *plan, *local, row| {
            var flow: Flow.Plan = undefined;
            var imports: TypeImports.Imports = undefined;

            inline for (comptime schedule.steps(.Module)) |step| switch (step) {
                .BeginModule => {
                    if (self.definitions.len != 0 and !self.store_memory.reset(.retain_capacity)) return error.OutOfMemory;

                    loader.owner = source.path;
                    loader.references = .{ .edges = edges };
                    loader.calls = .empty;
                    loader.local_calls = true;
                    loader.arguments = .empty;
                    loader.plan = .{};
                    loader.task_count = 0;
                    loader.deferred_shortcut = false;
                },
                .ResolveStores => {
                    const result = try StoreReferences.resolve(loader.allocator, self.store_memory.allocator(), source, edges, loader.signatures.graph.sources, self.definitions);

                    loader.stores = switch (result) {
                        .scope => |scope| scope,
                        .diagnostic => |issue| {
                            loader.issue = issue;

                            return error.InvalidFlow;
                        },
                    };
                },
                .PrepareBody => flow = try loader.moduleBody(source),
                .ImportTypes => {
                    const result = try TypeImports.collect(loader.allocator, loader.allocator, source, edges, loader.signatures, loader.project.context.types.kinds);

                    imports = switch (result) {
                        .imports => |found| found,
                        .diagnostic => |issue| {
                            loader.issue = issue;

                            return error.InvalidFlow;
                        },
                    };
                },
                .PublishModule => {
                    try loader.inputs.publish(self.modules.len, row, loader.arguments.items);

                    plan.* = .{
                        .source = source,
                        .deferred_shortcut = loader.deferred_shortcut,
                        .calls = loader.calls.slice(),
                        .plan = flow,
                        .type_imports = imports.types,
                        .value_imports = imports.values,
                    };

                    local.* = loader.local_calls;
                },
                else => unreachable,
            };
        }
    }
};
