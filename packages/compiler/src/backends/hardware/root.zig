const std = @import("std");
const zx = @import("zx");
const Conditions = @import("../../verification/conditions.zig");
const scratch_buffer_size = 32 * 1024;
pub const ir = @import("ir.zig");
pub const validate = @import("validate.zig").validate;
pub const Circuit = @import("graph/circuit.zig");
pub const Result = Generated(ir.Module);
pub const CircuitResult = Generated(Circuit);

fn Generated(comptime Graph: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        value: union(enum) { module: Graph, diagnostic: zx.Diagnostic },
        pub fn deinit(self: *@This()) void {
            self.arena.deinit();

            self.* = undefined;
        }
    };
}

pub fn generate(allocator: std.mem.Allocator, program: zx.ir.Program) std.mem.Allocator.Error!Result {
    return generateGraph(ir.Module, allocator, program);
}

pub fn generateCircuit(allocator: std.mem.Allocator, program: zx.ir.Program) std.mem.Allocator.Error!CircuitResult {
    return generateGraph(Circuit, allocator, program);
}

fn generateGraph(comptime Graph: type, allocator: std.mem.Allocator, program: zx.ir.Program) std.mem.Allocator.Error!Generated(Graph) {
    var arena = std.heap.ArenaAllocator.init(allocator);

    errdefer arena.deinit();

    if (try @import("frontend").validateIr(allocator, program)) |issue| return .{ .arena = arena, .value = .{ .diagnostic = issue } };

    var symbolic = std.heap.ArenaAllocator.init(allocator);

    defer symbolic.deinit();

    var buffer: [scratch_buffer_size]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, symbolic.allocator());
    const scratch = memory.allocator();
    var reporter: zx.Reporter = .{};
    var evaluation_scratch = zx.Arena.init(allocator);

    defer evaluation_scratch.deinit();

    var conditions = Conditions{ .allocator = scratch, .scratch = &evaluation_scratch, .program = program, .reporter = &reporter };

    const model = conditions.model(arena.allocator()) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        return .{ .arena = arena, .value = .{ .diagnostic = reporter.diagnostic orelse diagnostic("unsupported hardware symbolic model") } };
    };

    const module = build(Graph, arena.allocator(), scratch, program, model) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        return .{ .arena = arena, .value = .{ .diagnostic = diagnostic("invalid or oversized typed hardware expression") } };
    };

    return .{ .arena = arena, .value = .{ .module = module } };
}

fn build(comptime Graph: type, allocator: std.mem.Allocator, scratch: std.mem.Allocator, program: zx.ir.Program, model: Conditions.Model) !Graph {
    return @import("construction/workflow.zig").build(Graph, allocator, scratch, program, model);
}

fn diagnostic(message: []const u8) zx.Diagnostic {
    return .{ .code = .unsupported, .span = .{ .start = 0, .end = 0 }, .message = message };
}
