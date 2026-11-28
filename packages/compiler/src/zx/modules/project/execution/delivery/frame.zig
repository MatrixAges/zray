const std = @import("std");
const zx = @import("zx");
const owner = @import("../../../project.zig");
const load = @import("../load.zig");
const input = @import("../../../module_input.zig");
const indexed = @import("../../../parse_cache.zig").indexed_enabled;
const Loading = @import("../../load/host.zig");
const Target = @import("../../target/host.zig");
const self_route = @import("route.zig");
const source = @import("source.zig");
const binding = @import("bind.zig");
const entry = @import("generated_project_import_delivery");
const State = std.meta.Child(@FieldType(entry.zx_pending, "store_0"));
const Effect = std.meta.Child(State);
const Self = @This();

const Item = union(enum) {
    native: @TypeOf(owner.import_view.get(@as(zx.syntax.header.Native, undefined), 0)),
    indexed: if (indexed) @TypeOf(owner.import_view.get(@as(input.Indexed, undefined).header(), 0)) else void,
};

walk: *load.Walk,
active: *owner.LoadFrame,
item: Item,
scope: Target.Scope = undefined,
route: Loading.Route = undefined,
duplicate: zx.ast.Name = undefined,
resolved: Target.Resolved = undefined,
imported: owner.Imported = undefined,
path_buffer: [512]u8 = undefined,
path_memory: std.heap.BufferFirstAllocator = undefined,
path_started: bool = false,
store_0: *State,
snapshot: *Effect,
pub fn commit(frame: *Self, pending: anytype) zx.Error!void {
    const effect = pending.store_0 orelse return;

    switch (effect.step) {
        .Route => {
            frame.snapshot.* = effect.*;
            const route = try self_route.route(frame);
            frame.snapshot.route = zx.columns.view(std.meta.Child(@FieldType(Effect, "route")), route);
        },
        .RejectRoute => return self_route.reject(frame, @fromBackingInt(@intCast(@backingInt(effect.route.?))), effect.message.?),
        .ReuseNative => {
            frame.snapshot.* = effect.*;
            frame.snapshot.flag = binding.reuseNative(frame);
        },
        .RegisterNative => {
            frame.snapshot.* = effect.*;
            frame.snapshot.native_row = try binding.registerNative(frame);
        },
        .LoadNative => return binding.loadNative(frame, effect.native_row.?),
        .RememberNative => return binding.rememberNative(frame, effect.native_row.?),
        .BindLegacy => return binding.bindLegacy(frame),
        .Resolve => {
            frame.snapshot.* = effect.*;
            frame.snapshot.flag = try self_route.resolve(frame);
        },
        .SelectSource => {
            const plan = source.select(frame);

            frame.snapshot.* = effect.*;
            frame.snapshot.action = zx.columns.view(std.meta.Child(@FieldType(Effect, "action")), plan.action);
            frame.snapshot.row = plan.index;
        },
        .LoadLibrary => return binding.loadLibrary(frame),
        .Bind => return binding.bind(frame, effect.target.?, effect.signature.?, effect.exported.?),
        .RejectSource => return source.reject(frame, effect.action.?),
        .Record => return binding.record(frame, effect.target.?),
    }

    frame.store_0.* = frame.snapshot;
}

pub fn sourceUnit(self: *const Self, row: u64) *const owner.Unit {
    const index: usize = @intCast(row);
    const project = self.walk.project;

    std.debug.assert(project.load_states[index] == .Done);

    return &project.units[index];
}

pub fn run(walk: *load.Walk, row: usize, completed: ?u64) zx.Error!?u64 {
    const Input = std.meta.Child(entry.Input);

    var snapshot: Effect = .{
        .step = .Route,
        .route = null,
        .action = null,
        .row = null,
        .native_row = null,
        .flag = null,
        .target = null,
        .signature = null,
        .exported = null,
        .message = null,
    };

    var store: State = &snapshot;

    var frame: Self = .{
        .store_0 = &store,
        .snapshot = &snapshot,
        .walk = walk,
        .active = walk.active(),
        .item = switch (walk.header) {
            .native => |header| .{ .native = owner.import_view.get(header, row) },
            .indexed => |header| if (indexed) .{ .indexed = owner.import_view.get(header, row) } else unreachable,
        },
    };

    defer if (frame.path_started) {
        _ = walk.paths.reset(.retain_capacity);
    };

    const request: Input = .{
        .signature = walk.phase == .signature,
        .exported = switch (frame.item) {
            inline else => |item| item.exported,
        },
        .completed = completed,
    };

    var arena = std.heap.ArenaAllocator.init(walk.project.arena.child_allocator);

    defer arena.deinit();

    var buffer: [256]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    return entry.executeIn(scratch.allocator(), &request, &frame) catch |err| switch (@as(anyerror, err)) {
        error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => @import("../invoke.zig").errorSet(err),
    };
}
