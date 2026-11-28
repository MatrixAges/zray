const std = @import("std");
const zx = @import("zx");
const terms = @import("terms.zig");
const Self = @This();
const limits = @import("generated_verification_graph_constants").@"zx.constants";
pub const Origin = struct { file_name: []const u8, span: zx.Span };
pub const Definition = struct { name: []const u8, expression: []const u8, width: u16, origin: Origin };
pub const Definitions = std.MultiArrayList(Definition);

allocator: std.mem.Allocator,
reporter: *zx.Reporter,
definitions: Definitions = .empty,
index: []u64 = &.{},
calls: @import("call_cache.zig").Cache = .{},
steps: usize = 0,
pub fn step(self: *Self, span: zx.Span) zx.Error!void {
    if (self.steps >= limits.max_steps) return self.reporter.fail(.unsupported, span, limits.step_limit_message);

    self.steps += 1;
}

pub fn bind(self: *Self, expression: []const u8, width: u16, origin: Origin) zx.Error![]const u8 {
    return @import("graph/registration.zig").bind(self, expression, width, origin);
}

pub fn appendDefinition(self: *Self, definition: Definition) void {
    self.definitions.appendAssumeCapacity(definition);
}

/// Every composite is assembled from evaluations whose scalar leaves are already bound.
pub fn retain(self: *Self, program: zx.ir.Program, type_id: zx.ir.TypeId, input: terms.Value, span: zx.Span) zx.Error!terms.Value {
    const text = input.scalar orelse return input;
    const width = terms.symbolicWidth(program.typeOf(type_id)) orelse return self.reporter.fail(.unsupported, span, "symbolic graph requires boolean, enum or fixed-width integer values");

    return .{ .scalar = try self.bind(text, width, .{ .file_name = program.file_name, .span = span }) };
}

pub fn select(self: *Self, program: zx.ir.Program, type_id: zx.ir.TypeId, condition: []const u8, yes: terms.Value, no: terms.Value, span: zx.Span) zx.Error!terms.Value {
    return @import("graph/selection.zig").select(self, &program, type_id, condition, &yes, &no, span);
}
