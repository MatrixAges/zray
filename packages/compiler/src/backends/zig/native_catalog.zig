const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const write = @import("generated_native_catalog_write");
const Names = std.meta.Child(write.Input);

pub fn create(owned: std.mem.Allocator, modules: ir.NativeModuleTable) std.mem.Allocator.Error!ir.NativeModuleTable {
    const count = modules.count();

    if (count == 0) return .{};
    if (comptime !@import("parser_options").generated_parser) return seed(owned, modules);

    const source: Names = .{ .identities = modules.identities, .import_names = modules.import_names, .specifiers = modules.specifiers };
    var arena = std.heap.ArenaAllocator.init(owned);

    defer arena.deinit();

    var buffer: [4096]u8 = undefined;
    var buffered = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    const result = zx.columns.invoke(write.executeValue, buffered.allocator(), &source) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    const data = try owned.dupe(u8, result.data);

    errdefer owned.free(data);

    const identities = try owned.alloc(?[]const u8, count);

    errdefer owned.free(identities);

    const view_count = std.math.mul(usize, count, 2) catch return error.OutOfMemory;
    const views = try owned.alloc([]const u8, view_count);

    errdefer owned.free(views);

    const specifiers = views[0..count];
    const import_names = views[count..];
    var offset: usize = 0;

    for (0..count) |index| {
        const specifier_len: usize = @intCast(result.specifier_lens[index]);
        specifiers[index] = data[offset..][0..specifier_len];
        offset += specifier_len;

        const import_len: usize = @intCast(result.import_lens[index]);

        import_names[index] = data[offset..][0..import_len];
        offset += import_len;

        identities[index] = if (result.identity_lens[index]) |len| item: {
            const width: usize = @intCast(len);
            const slice = data[offset..][0..width];
            offset += width;

            break :item slice;
        } else null;
    }

    const empty_names = try owned.alloc([]const []const u8, count);

    errdefer owned.free(empty_names);

    const empty_ids = try owned.alloc([]const u32, count);

    @memset(empty_names, &.{});
    @memset(empty_ids, &.{});

    return .{
        .identities = identities,
        .import_names = import_names,
        .specifiers = specifiers,
        .type_ids = empty_ids,
        .type_names = empty_names,
        .type_namespaces = empty_names,
    };
}

fn seed(owned: std.mem.Allocator, modules: ir.NativeModuleTable) std.mem.Allocator.Error!ir.NativeModuleTable {
    var storage: ir.NativeModuleStorage = .{};

    errdefer storage.deinit(owned);

    for (0..modules.count()) |index| {
        const module = modules.at(index);

        try storage.append(owned, .{
            .specifier = try owned.dupe(u8, module.specifier),
            .identity = if (module.identity) |identity| try owned.dupe(u8, identity) else null,
            .import_name = try owned.dupe(u8, module.import_name),
        });
    }

    return storage.finish(owned);
}
