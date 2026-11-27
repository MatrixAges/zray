const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const model = @import("../compiled.zig");
const View = @import("host/graph.zig").View;
pub const Error = std.mem.Allocator.Error || error{InvalidLibrary};
pub const LinkError = Error || error{ InvalidIr, ConflictingStore };

pub fn validate(allocator: std.mem.Allocator, library: model.Graph) Error!void {
    return validateIndexed(allocator, library, null);
}

pub fn validateIndexed(allocator: std.mem.Allocator, library: model.Graph, names: ?*model.ExportIndex) Error!void {
    if (comptime !@import("parser_options").generated_parser) {
        try @import("seed_validate.zig").validate(allocator, library);
        if (names) |index| try index.finish(library.exports);

        return;
    }

    var scratch = std.heap.ArenaAllocator.init(allocator);

    defer scratch.deinit();

    const temporary = scratch.allocator();
    const rule = @import("generated_compiled_validation");
    const Input = std.meta.Child(rule.Input);
    var graph: View(std.meta.Child(@FieldType(Input, "graph"))) = undefined;

    graph.init(temporary, &library);

    const buckets: []u64 = if (names) |value| value.storage else &.{};
    const input: Input = .{ .graph = &graph.input, .index_capacity = buckets.len };

    const accepted = zx.columns.invoke(rule.executeValue, temporary, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => return error.InvalidLibrary,
    };

    if (!accepted.valid) return error.InvalidLibrary;
    if (buckets.len != 0) @memcpy(buckets, accepted.export_index);
}

pub fn validateLinked(allocator: std.mem.Allocator, library: model.Graph) LinkError!void {
    if (comptime !@import("parser_options").generated_parser) return @import("seed_validate.zig").validateLinked(allocator, library);

    var scratch = std.heap.ArenaAllocator.init(allocator);

    defer scratch.deinit();

    const temporary = scratch.allocator();
    const rule = @import("generated_compiled_linked_validation");
    const Input = std.meta.Child(rule.Input);
    var graph: View(std.meta.Child(@FieldType(Input, "graph"))) = undefined;

    graph.init(temporary, &library);

    const StoreState = std.meta.Child(@FieldType(rule.zx_pending, "store_0"));

    const StoreHost = struct {
        store_0: *StoreState,
        pub fn commit(self: *@This(), pending: anytype) error{}!void {
            if (pending.store_0) |next| self.store_0.* = next;
        }
    };

    var state_value: std.meta.Child(StoreState) = .{ .ir_started = false, .surface_started = false };
    var state_ptr: StoreState = &state_value;
    var host: StoreHost = .{ .store_0 = &state_ptr };
    const input: Input = .{ .graph = &graph.input };

    const status = rule.executeIn(temporary, &input, &host) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        error.IntegerOverflow, error.Overflow => return if (state_ptr.ir_started) error.OutOfMemory else error.InvalidIr,
        else => return if (state_ptr.surface_started) error.InvalidLibrary else error.InvalidIr,
    };

    return switch (status) {
        .Valid => {},
        .ConflictingStore => error.ConflictingStore,
        .InvalidIr => error.InvalidIr,
        .InvalidLibrary => error.InvalidLibrary,
    };
}

pub fn validateHeader(program: *const ir.Program, public_count: usize) error{InvalidLibrary}!void {
    if (comptime !@import("parser_options").generated_parser) return @import("seed_validate.zig").validateHeader(program, public_count);

    return @import("host/header.zig").validate(program, public_count);
}
