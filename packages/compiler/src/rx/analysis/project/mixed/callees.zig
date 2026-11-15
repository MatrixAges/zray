const std = @import("std");
const rx = @import("rx");
const frontend = @import("frontend");
const zx = @import("zx");
const ir = zx.ir;
const State = @import("state.zig");
const Prepared = @import("../prepare.zig");
const missing_rx = "RX call target has not been lowered";
const missing_zx = "source call target has not been analyzed in its required context";
const not_executable_rx = "Call.module requires an executable source module";
const not_executable_zx = "Call requires an executable source module";

pub fn load(state: *State, allocator: std.mem.Allocator, cache: *frontend.project.ParseCache, sources: []const frontend.project.Source, module: Prepared.Module) State.Error![]const ir.FunctionId {
    const owner = state.owner;
    const ids = try allocator.alloc(ir.FunctionId, module.calls.len);

    if (comptime !Prepared.batch_callees) return loadSeed(state, cache, sources, module.calls, ids);
    if (ids.len == 0) return ids;

    const rule = @import("generated_rx_mixed_callees");
    const Input = std.meta.Child(rule.Input);
    const graph = &state.graph;
    const kinds = module.calls.items(.target_kind);
    const targets = module.calls.items(.target);
    const nodes = module.calls.items(.node);
    const setters = module.calls.items(.setter);

    var request: Input = .{
        .calls = &.{ .kinds = kinds, .rows = @ptrCast(targets) },
        .published = &.{ .present = state.finished.present, .functions = state.finished.functions },
        .zx_count = graph.sources.zx_count,
        .rx_end = graph.sources.rx_end,
        .ids = @ptrCast(&ids),
        .first = 0,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    while (request.first < ids.len) {
        const input: *const Input = &request;
        const next = zx.columns.invoke(rule.executeValue, empty.allocator(), input) catch unreachable;

        if (next.action == .Done) break;

        const position: usize = @intCast(next.position);
        const target: usize = @intCast(next.target);
        const location = nodes[position].location;
        const setter = setters[position];

        ids[position] = switch (next.action) {
            .LoadLibrary => try loadLibrary(state, owner, target, location, setter != null),
            .CompileSetter => try compileSetter(state, cache, sources, owner, target, setter.?, location),
            .MissingRX => return state.fail(location, missing_rx),
            .MissingZX => return state.fail(location, missing_zx),
            .NotExecutableRX => return state.fail(location, not_executable_rx),
            .NotExecutableZX => return state.fail(location, not_executable_zx),
            .Done, .Bind => unreachable,
        };

        request.first = next.position + 1;
    }

    return ids;
}

fn loadLibrary(state: *State, owner: usize, edge: usize, location: rx.ast.Location, setter: bool) State.Error!ir.FunctionId {
    const target = state.graph.modules.items(.dependencies)[owner][edge].target.compiled;
    const exported = try @import("library.zig").load(state, target, location, "");

    return switch (@import("../../call/compiled_admission.zig").check(exported.function, &state.functions, setter)) {
        .Executable => exported.function.?,
        .MissingFunction => state.fail(location, "Call.module requires an executable public module"),
        .Setter, .Transaction => state.fail(location, "compiled Store transactions require an explicit authorized RX module"),
    };
}

fn compileSetter(state: *State, cache: *frontend.project.ParseCache, sources: []const frontend.project.Source, owner: usize, index: usize, setter: @import("../../call/target.zig").Setter, location: rx.ast.Location) State.Error!ir.FunctionId {
    const loaded = try @import("zx.zig").compile(state, cache, sources, index, setter);

    state.owner = owner;

    return loaded.function orelse state.fail(location, not_executable_zx);
}

fn loadSeed(state: *State, cache: *frontend.project.ParseCache, sources: []const frontend.project.Source, calls: Prepared.Calls.Slice, ids: []ir.FunctionId) State.Error![]const ir.FunctionId {
    const owner = state.owner;

    for (calls.items(.target_kind), calls.items(.target), calls.items(.node), calls.items(.setter), ids) |kind, target, node, setter, *id| {
        const location = node.location;

        if (kind == .Compiled) {
            id.* = try loadLibrary(state, owner, target, location, setter != null);

            continue;
        }

        const is_rx = state.graph.sources.at(target) == .rx;

        if (kind == .AuthorizedSource and !is_rx) {
            id.* = try compileSetter(state, cache, sources, owner, target, setter.?, location);

            continue;
        }

        if (!state.finished.present[target]) return state.fail(location, if (is_rx) missing_rx else missing_zx);

        id.* = state.finished.function(target) orelse return state.fail(location, if (is_rx) not_executable_rx else not_executable_zx);
    }

    return ids;
}
