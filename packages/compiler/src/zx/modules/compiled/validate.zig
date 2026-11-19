const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const model = @import("../compiled.zig");
const View = @import("host/graph.zig").View;
pub const Error = std.mem.Allocator.Error || error{InvalidLibrary};
pub const LinkError = Error || error{ InvalidIr, ConflictingStore };

pub fn validate(allocator: std.mem.Allocator, library: model.Graph) Error!void {
    if (comptime !@import("parser_options").generated_parser) return @import("seed_validate.zig").validate(allocator, library);

    var scratch = std.heap.ArenaAllocator.init(allocator);

    defer scratch.deinit();

    const temporary = scratch.allocator();
    const rule = @import("generated_compiled_validation");
    var graph: View(std.meta.Child(rule.Input)) = undefined;

    graph.init(temporary, &library);

    const input: *const @TypeOf(graph.input) = &graph.input;

    const accepted = zx.columns.invoke(rule.executeValue, temporary, input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => return error.InvalidLibrary,
    };

    if (!accepted) return error.InvalidLibrary;
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

    var ir_started = [_]u8{0};
    var surface_started = [_]u8{0};
    const ir_mark: []u8 = &ir_started;
    const surface_mark: []u8 = &surface_started;
    const input: Input = .{ .graph = &graph.input, .ir_started = @ptrCast(&ir_mark), .surface_started = @ptrCast(&surface_mark) };

    const status = zx.columns.invoke(rule.executeValue, temporary, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        error.IntegerOverflow, error.Overflow => return if (ir_started[0] != 0) error.OutOfMemory else error.InvalidIr,
        else => return if (surface_started[0] != 0) error.InvalidLibrary else error.InvalidIr,
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
