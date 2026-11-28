const std = @import("std");
const ir = @import("zx").ir;
const rows = @import("../../exports/publication/rows.zig");
const FunctionImport = @import("../../../function_import.zig");
const project = @import("../../../project.zig");
const rule = @import("generated_project_execute_body");
const Body = std.meta.Child(rule.Input);
const Input = std.meta.Child(@FieldType(Body, "exports"));
const Exports = std.meta.Child(@FieldType(Input, "exports"));
const Layout = struct { name: *const anyopaque, id: *const anyopaque };
const Self = @This();

types: rows.Rows(ir.Export, std.meta.Child(@FieldType(Exports, "types")), rows.Names),
constants: rows.Rows(ir.Constant, std.meta.Child(@FieldType(Exports, "constants")), rows.Names),
members: rows.Rows(FunctionImport, std.meta.Child(@FieldType(Input, "members")), Layout),
own: FunctionImport,
type_rows: std.meta.Child(@FieldType(Exports, "types")),
constant_rows: std.meta.Child(@FieldType(Exports, "constants")),
member_rows: std.meta.Child(@FieldType(Input, "members")),
exports: Exports,
input: Input,
bound: bool,
pub fn bind(self: *Self, program: *const ir.Program, frame: *const project.LoadFrame, entry: ?ir.FunctionId) void {
    self.type_rows = self.types.borrow(program.exports, frame.export_aliases.items, false);
    self.constant_rows = self.constants.borrow(program.constant_exports, frame.export_constants.items, false);

    const own: []const FunctionImport = if (entry) |id| block: {
        self.own = .{ .name = "", .id = id, .input_type = program.input_type, .output_type = program.output_type };

        break :block @as(*const [1]FunctionImport, @ptrCast(&self.own));
    } else &.{};

    self.member_rows = self.members.borrow(own, frame.export_functions.items, entry != null);
    self.exports = .{ .types = &self.type_rows, .constants = &self.constant_rows };

    self.input = .{
        .exports = &self.exports,
        .members = &self.member_rows,
        .ids = @ptrCast(self.members.column("id")),
        .entry = if (entry) |id| @backingInt(id) else null,
    };

    self.bound = true;
}

pub fn commit(self: *Self, allocator: std.mem.Allocator, row: anytype) std.mem.Allocator.Error!void {
    switch (row.kind) {
        .Types => try self.types.merge(allocator),
        .Constants => try self.constants.merge(allocator),
        .Members => try self.members.merge(allocator),
    }
}

pub fn release(self: *const Self, allocator: std.mem.Allocator) void {
    if (!self.bound) return;

    allocator.free(self.types.allocated);
    allocator.free(self.constants.allocated);
    allocator.free(self.members.allocated);
}
