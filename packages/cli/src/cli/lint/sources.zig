const std = @import("std");
const Compile = @import("../compile.zig");
const Module = @import("../library/analyze.zig").Module;
const Source = @import("compiler").project.Source;
const effects = @import("../sources/effects.zig");
const Error = effects.Error;

const State = struct {
    context: *const Compile.Context,
    sources: []const *const Source,
    store_paths: []const []const u8,
    failure: effects.Failure = .{},
    fn get(handle: *const anyopaque) *State {
        return effects.state(State, handle);
    }
};

const reachable = @import("cli_source").lint_reachable;
const StoreState = std.meta.Child(@FieldType(reachable.zx_pending, "store_0"));

const StoreHost = struct {
    store_0: *StoreState,
    pub fn commit(self: *StoreHost, pending: anytype) error{}!void {
        if (pending.store_0) |next| self.store_0.* = next;
    }
};

pub fn check(context: Compile.Context, modules: []const Module, root: []const u8) !Compile.Status {
    var arena = std.heap.ArenaAllocator.init(context.allocator);

    defer arena.deinit();

    const allocator = arena.allocator();
    const Input = std.meta.Child(reachable.Input);
    const ItemSlot = std.meta.Child(@FieldType(Input, "items"));
    const Item = if (@typeInfo(ItemSlot) == .pointer) std.meta.Child(ItemSlot) else ItemSlot;
    var source_count: usize = 0;
    var store_count: usize = 0;

    for (modules) |module| {
        source_count += module.sources.len;
        store_count += module.store_definitions.len;
    }

    const source_list = try allocator.alloc(*const Source, source_count);
    const store_paths = try allocator.alloc([]const u8, store_count);
    const items = try allocator.alloc(ItemSlot, source_count + store_count);
    var source_index: usize = 0;
    var store_index: usize = 0;
    var item_index: usize = 0;

    for (modules) |module| {
        for (module.sources) |*source| {
            source_list[source_index] = source;
            items[item_index] = try buildItem(allocator, ItemSlot, Item, source.path, false, source_index);
            source_index += 1;
            item_index += 1;
        }

        for (module.store_definitions) |*definition| {
            const path = try std.fs.path.resolve(allocator, &.{ root, definition.source_path });

            store_paths[store_index] = path;
            items[item_index] = try buildItem(allocator, ItemSlot, Item, path, true, store_index);
            store_index += 1;
            item_index += 1;
        }
    }

    var state: State = .{ .context = &context, .sources = source_list, .store_paths = store_paths };
    const reference = &state;
    var visited: StoreState = &.{ .paths = &.{} };
    var host: StoreHost = .{ .store_0 = &visited };
    const valid = reachable.execute(&arena, &.{ .check = @ptrCast(&reference), .items = items }, &host) catch |err| return state.failure.unwrap(err);

    return if (valid) .success else .failed;
}

fn buildItem(allocator: std.mem.Allocator, comptime Slot: type, comptime Item: type, path: []const u8, is_store: bool, row: usize) !Slot {
    const value: Item = .{ .path = path, .is_store = is_store, .row = row };

    if (Slot == Item) return value;

    const slot = try allocator.create(Item);

    slot.* = value;

    return slot;
}

pub fn checkReachableLintSource(handle: *const anyopaque, row: u64) Error!bool {
    const self = State.get(handle);
    const source = self.sources[@intCast(row)];
    var selected = self.context.*;
    selected.options.input = source.path;
    const status = @import("../lint.zig").checkSource(selected, source.source) catch |err| return self.failure.save(err);

    return status == .success;
}

pub fn checkReachableLintStore(handle: *const anyopaque, row: u64) Error!bool {
    const self = State.get(handle);
    const status = file(self.context.*, self.store_paths[@intCast(row)]) catch |err| return self.failure.save(err);

    return status == .success;
}

pub fn file(context: Compile.Context, path: []const u8) !Compile.Status {
    var selected = context;
    selected.options.input = path;
    const source = try std.Io.Dir.cwd().readFileAlloc(context.io, path, context.allocator, .limited(16 * 1024 * 1024));

    defer context.allocator.free(source);

    return @import("../lint.zig").checkSource(selected, source);
}
