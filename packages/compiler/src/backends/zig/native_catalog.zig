const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const size = @import("generated_native_catalog_size");
const write = @import("generated_native_catalog_write");
const Input = std.meta.Child(write.Input);
const Names = std.meta.Child(@FieldType(Input, "source"));

pub fn create(owned: std.mem.Allocator, modules: ir.NativeModuleTable) std.mem.Allocator.Error!ir.NativeModuleTable {
    const count = modules.count();

    if (count == 0) return .{};
    if (comptime !@import("parser_options").generated_parser) return seed(owned, modules);

    const source: Names = .{ .identities = modules.identities, .import_names = modules.import_names, .specifiers = modules.specifiers };
    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    const total = zx.columns.invoke(size.executeValue, fixed.allocator(), &source) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    const data = try owned.alloc(u8, std.math.cast(usize, total) orelse return error.OutOfMemory);

    errdefer owned.free(data);

    const identities = try owned.alloc(?[]const u8, count);

    errdefer owned.free(identities);

    const view_count = std.math.mul(usize, count, 2) catch return error.OutOfMemory;
    const views = try owned.alloc([]const u8, view_count);

    errdefer owned.free(views);

    const specifiers = views[0..count];
    const import_names = views[count..];
    const empty_names = try owned.alloc([]const []const u8, count);

    errdefer owned.free(empty_names);

    const empty_ids = try owned.alloc([]const u32, count);

    @memset(empty_names, &.{});
    @memset(empty_ids, &.{});

    const input: Input = .{
        .source = &source,
        .text = &.{ .data = data, .bytes = @ptrCast(&data) },
        .target = &.{ .identities = @ptrCast(&identities), .import_names = @ptrCast(&import_names), .specifiers = @ptrCast(&specifiers) },
    };

    zx.columns.invoke(write.executeValue, fixed.allocator(), &input) catch unreachable;

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
