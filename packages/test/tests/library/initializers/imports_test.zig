const std = @import("std");
const allocation_testing = @import("allocation_testing");
const f = @import("fixture.zig");
const imported = @import("import_fixture.zig");

fn check(allocator: std.mem.Allocator, distinct: bool) !void {
    var analyzed = try imported.analyze(allocator, distinct, false);

    defer analyzed.deinit();

    try std.testing.expect(analyzed.value == .ir);

    const count: usize = if (distinct) 2 else 1;

    try std.testing.expectEqual(count, analyzed.value.ir.stores.count());
    try std.testing.expectEqual(count, analyzed.store_initializers.len);
    if (distinct) try std.testing.expect(!std.mem.eql(u8, analyzed.store_initializers[0].identity, analyzed.store_initializers[1].identity));

    var result = try f.compiler.library.link(allocator, &.{.{ .name = "relay", .analysis = &analyzed }});

    defer result.deinit();

    try f.check(&result, count);

    const bytes = try f.compiler.library.codec.encode(allocator, &result);

    defer allocator.free(bytes);

    var restored = try f.compiler.library.codec.decode(allocator, bytes);

    defer restored.deinit();

    try std.testing.expectEqualDeep(result.store_initializers, restored.store_initializers);
    try f.check(&restored, count);
}

test "same compiled instance shares initializer across aliases and republication" {
    try check(std.testing.allocator, false);
}

test "distinct compiled instances keep independent Store initializers through republication" {
    try check(std.testing.allocator, true);
}

test "Store initializer metadata does not permit ZX to import an RX library entry" {
    var result = try imported.analyze(std.testing.allocator, false, true);

    defer result.deinit();

    try std.testing.expect(result.value == .diagnostic);
    try std.testing.expectEqual(.module, result.value.diagnostic.code);
    try std.testing.expect(std.mem.startsWith(u8, result.value.diagnostic.message, "ZX cannot import RX modules"));
}

test "compiled Store initialization import and republication clean partial allocations" {
    try allocation_testing.checkAllAllocationFailures(std.testing.allocator, check, .{true});
}
