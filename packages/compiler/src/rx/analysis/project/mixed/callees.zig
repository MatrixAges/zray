const std = @import("std");
const rx = @import("rx");
const frontend = @import("frontend");
const zx = @import("zx");
const ir = zx.ir;
const State = @import("state.zig");
const result_name = @import("../../result_name.zig");
const Prepared = @import("../prepare.zig");
const missing_rx = "RX call target has not been lowered";
const missing_zx = "source call target has not been analyzed in its required context";
const not_executable_rx = "Call.module requires an executable source module";
const not_executable_zx = "Call requires an executable source module";

pub fn load(state: *State, allocator: std.mem.Allocator, cache: *frontend.project.ParseCache, sources: []const frontend.project.Source, module: Prepared.Module) State.Error![]const ir.FunctionId {
    if (module.calls.len == 0) return &.{};

    if (comptime !Prepared.batch_callees) {
        const ids = try allocator.alloc(ir.FunctionId, module.calls.len);

        errdefer allocator.free(ids);

        return try loadSeed(state, cache, sources, module.calls, ids);
    }

    const rule = @import("generated_rx_mixed_callees");
    const Input = std.meta.Child(rule.Input);
    const graph = &state.graph;
    const kinds = module.calls.items(.target_kind);
    const targets = module.calls.items(.target);
    const names = module.calls.items(.name_source);
    const references = zx.memory.borrowReferencedTextColumn("value", names);
    const members = @import("../../call/named.zig").MemberColumns.borrow(&.{"members"}, state.finished.surfaces);
    const Published = std.meta.Child(@FieldType(Input, "published"));
    const binding: Binding = .{ .state = state, .cache = cache, .sources = sources, .calls = module.calls, .owner = state.owner };

    var request: Input = .{
        .calls = &.{ .kinds = kinds, .rows = @ptrCast(targets), .references = @ptrCast(&references) },
        .published = &.{ .present = state.finished.present, .functions = state.finished.functions, .members = &members.view(std.meta.Child(@FieldType(Published, "members"))) },
        .zx_count = graph.sources.zx_count,
        .rx_end = graph.sources.rx_end,
        .position = 0,
        .reply = null,
    };

    var scratch = std.heap.ArenaAllocator.init(state.scratch.child_allocator);

    defer scratch.deinit();

    const Reply = std.meta.Child(std.meta.Child(@FieldType(Input, "reply")));
    const Imported = std.meta.Child(std.meta.Child(@FieldType(Reply, "library")));
    var reply: Reply = undefined;
    var imported: Imported = undefined;
    const ids = try allocator.alloc(ir.FunctionId, module.calls.len);

    errdefer allocator.free(ids);

    var written: usize = 0;

    while (true) {
        const next = rule.executeIn(scratch.allocator(), &request) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
            else => unreachable,
        };

        @memcpy(ids[written..][0..next.ids.len], @as([]const ir.FunctionId, @ptrCast(next.ids)));

        written += next.ids.len;

        const effect = next.effect;
        request.position = effect.position;

        reply = switch (effect.kind) {
            .Done => {
                std.debug.assert(written == ids.len);

                return ids;
            },
            .ImportLibrary => block: {
                imported = try binding.openLibrary(Imported, @intCast(effect.position), @intCast(effect.target.?));

                break :block .{ .library = &imported, .setter = null };
            },
            .CompileSetter => .{ .library = null, .setter = try binding.compile(@intCast(effect.position), @intCast(effect.target.?)) },
            .Reject => return binding.reject(@intCast(effect.position), effect.name orelse false, effect.message.?),
        };

        request.reply = &reply;
    }
}

const Binding = struct {
    state: *State,
    cache: *frontend.project.ParseCache,
    sources: []const frontend.project.Source,
    calls: Prepared.Calls.Slice,
    owner: usize,
    fn openLibrary(binding: *const Binding, comptime Imported: type, position: usize, edge: usize) State.Error!Imported {
        const location = binding.calls.items(.node)[position].location;
        const loaded = try importLibrary(binding.state, binding.owner, edge, location);
        const index = if (loaded) |id| @backingInt(id) else null;
        const functions = &binding.state.functions;

        return .{
            .function_id = index,
            .setter = binding.calls.items(.setter)[position] != null,
            .has_stores = if (index) |id| functions.stores.items[id].count() != 0 else false,
            .orchestration = if (index) |id| functions.store_modes.items[id] == .orchestration else false,
        };
    }
    fn compile(binding: *const Binding, row: usize, target: usize) State.Error!?u32 {
        const setter = binding.calls.items(.setter)[row].?;
        const id = try compileAuthorized(binding.state, binding.cache, binding.sources, target, setter);

        binding.state.owner = binding.owner;

        return id;
    }
    fn reject(binding: *const Binding, position: usize, name: bool, message: []const u8) State.Error {
        const location = if (name) binding.calls.items(.name_source)[position].value_location else binding.calls.items(.node)[position].location;

        return binding.state.fail(location, message);
    }
};

fn importLibrary(state: *State, owner: usize, edge: usize, location: rx.ast.Location) State.Error!?ir.FunctionId {
    const target = state.graph.modules.items(.dependencies)[owner][edge].target.compiled;
    const exported = try @import("library.zig").load(state, target, location, "");

    return exported.function;
}

fn loadLibrary(state: *State, owner: usize, edge: usize, location: rx.ast.Location, setter: bool) State.Error!ir.FunctionId {
    const function = try importLibrary(state, owner, edge, location);

    return switch (@import("../../call/compiled_admission.zig").check(function, &state.functions, setter)) {
        .Executable => function.?,
        .MissingFunction => state.fail(location, "Call.module requires an executable public module"),
        .Setter, .Transaction => state.fail(location, "compiled Store transactions require an explicit authorized RX module"),
    };
}

fn compileSetter(state: *State, cache: *frontend.project.ParseCache, sources: []const frontend.project.Source, owner: usize, index: usize, setter: @import("../../call/target.zig").Setter, location: rx.ast.Location) State.Error!ir.FunctionId {
    const function = try compileAuthorized(state, cache, sources, index, setter);

    state.owner = owner;

    return if (function) |id| @fromBackingInt(id) else state.fail(location, not_executable_zx);
}

fn compileAuthorized(state: *State, cache: *frontend.project.ParseCache, sources: []const frontend.project.Source, index: usize, setter: @import("../../call/target.zig").Setter) State.Error!?u32 {
    var loaded: frontend.project.artifact.source_link.Loaded = undefined;

    try @import("zx.zig").compile(state, cache, sources, index, setter, .{ .value = loaded.destination() });

    return loaded.function;
}

fn loadSeed(state: *State, cache: *frontend.project.ParseCache, sources: []const frontend.project.Source, calls: Prepared.Calls.Slice, ids: []ir.FunctionId) State.Error![]const ir.FunctionId {
    const owner = state.owner;

    for (calls.items(.target_kind), calls.items(.target), calls.items(.node), calls.items(.setter), calls.items(.name_source), ids) |kind, target, node, setter, name, *id| {
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

        if (kind == .NamedSource) {
            id.* = state.finished.namedFunction(target, result_name.resolveCall(name.*).name) orelse return state.fail(name.value_location, "selected ZX export was not linked");

            continue;
        }

        id.* = state.finished.function(target) orelse return state.fail(location, if (is_rx) not_executable_rx else not_executable_zx);
    }

    return ids;
}
