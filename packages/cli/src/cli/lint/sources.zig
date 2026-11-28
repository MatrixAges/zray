const std = @import("std");
const Compile = @import("../compile.zig");
const Module = @import("../library/analyze.zig").Module;
const source_lint = @import("source.zig");
const lint = @import("lint");
const rx = @import("rx");
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
    var item_count: usize = 0;

    for (modules) |module| {
        item_count += module.sources.len + module.store_definitions.len;
    }

    const items = try allocator.alloc(ItemSlot, item_count);
    var item_index: usize = 0;

    for (modules) |module| {
        for (module.sources) |*source| {
            items[item_index] = try buildItem(allocator, ItemSlot, Item, source.path, source.source);
            item_index += 1;
        }

        for (module.store_definitions) |*definition| {
            const path = try std.fs.path.resolve(allocator, &.{ root, definition.source_path });

            items[item_index] = try buildItem(allocator, ItemSlot, Item, path, null);
            item_index += 1;
        }
    }

    var visited: StoreState = &.{ .paths = &.{} };
    var host: StoreHost = .{ .store_0 = &visited };
    var parsed: ?rx.document.Parsed = null;
    const document = &parsed;

    defer rx.document.release(&parsed);

    const failure = (try reachable.execute(&arena, &.{
        .document = @ptrCast(&document),
        .maximum_lines = context.options.max_lines orelse lint.length.default_maximum,
        .items = items,
    }, &host, context.io)) orelse return .success;

    if (failure.error_name) |name| {
        try context.stderr.print("{s}: semantic lint: {s}\n", .{ context.options.input, name });

        return .failed;
    }

    return source_lint.report(context.stderr, failure.path, failure.result.?);
}

fn buildItem(allocator: std.mem.Allocator, comptime Slot: type, comptime Item: type, path: []const u8, source: ?[]const u8) !Slot {
    const value: Item = .{ .path = path, .source = source };

    if (Slot == Item) return value;

    const slot = try allocator.create(Item);

    slot.* = value;

    return slot;
}

pub fn file(context: Compile.Context, path: []const u8) !Compile.Status {
    var selected = context;
    selected.options.input = path;
    const source = try std.Io.Dir.cwd().readFileAlloc(context.io, path, context.allocator, .limited(16 * 1024 * 1024));

    defer context.allocator.free(source);

    return @import("../lint.zig").checkSource(selected, source);
}
