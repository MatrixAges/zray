const std = @import("std");
const model = @import("model.zig");
const schema = @import("../ir/schema.zig");
const Self = @This();
const ir = @import("../ir.zig");

statement_kinds: schema.storage(model.Table, "statement_kinds") = .empty,
statement_payloads: schema.storage(model.Table, "statement_payloads") = .empty,
evaluations: schema.storage(model.Table, "evaluations") = .empty,
constant_symbols: schema.storage(model.Table, "constant_symbols") = .empty,
constant_values: schema.storage(model.Table, "constant_values") = .empty,
parallel_first: schema.storage(model.Table, "parallel_first") = .empty,
parallel_count: schema.storage(model.Table, "parallel_count") = .empty,
parallel_symbols: schema.storage(model.Table, "parallel_symbols") = .empty,
parallel_values: schema.storage(model.Table, "parallel_values") = .empty,
destructure_values: schema.storage(model.Table, "destructure_values") = .empty,
destructure_first: schema.storage(model.Table, "destructure_first") = .empty,
destructure_count: schema.storage(model.Table, "destructure_count") = .empty,
destructure_symbols: schema.storage(model.Table, "destructure_symbols") = .empty,
branch_conditions: schema.storage(model.Table, "branch_conditions") = .empty,
branch_yes: schema.storage(model.Table, "branch_yes") = .empty,
branch_no: schema.storage(model.Table, "branch_no") = .empty,
selection_subjects: schema.storage(model.Table, "selection_subjects") = .empty,
selection_first: schema.storage(model.Table, "selection_first") = .empty,
selection_count: schema.storage(model.Table, "selection_count") = .empty,
selection_exhaustive: schema.storage(model.Table, "selection_exhaustive") = .empty,
case_values: schema.storage(model.Table, "case_values") = .empty,
case_bodies: schema.storage(model.Table, "case_bodies") = .empty,
setter_slots: schema.storage(model.Table, "setter_slots") = .empty,
setter_values: schema.storage(model.Table, "setter_values") = .empty,
results: schema.storage(model.Table, "results") = .empty,
block_first: schema.storage(model.Table, "block_first") = .empty,
block_count: schema.storage(model.Table, "block_count") = .empty,
pub const appendBlock = @import("append.zig").block;

pub fn view(self: *const Self) model.Table {
    var result: model.Table = .{};

    inline for (@typeInfo(model.Table).@"struct".field_names) |name| {
        @field(result, name) = @field(self, name).items;
    }

    return result;
}

pub fn finish(self: *Self, allocator: std.mem.Allocator, root: ?ir.BlockId) std.mem.Allocator.Error!@import("root.zig") {
    if (root == null) {
        std.debug.assert(self.block_first.items.len == 0);
        self.deinit(allocator);

        return .{};
    }

    const table = allocator.create(model.Table) catch |err| {
        self.deinit(allocator);

        return err;
    };

    table.* = .{};

    const complete = collect: {
        inline for (@typeInfo(model.Table).@"struct".field_names) |name| {
            @field(table, name) = @field(self, name).toOwnedSlice(allocator) catch break :collect false;
        }

        break :collect true;
    };

    if (!complete) {
        inline for (@typeInfo(model.Table).@"struct".field_names) |name| allocator.free(@field(table, name));
        allocator.destroy(table);
        self.deinit(allocator);

        return error.OutOfMemory;
    }

    return .{ .control = table, .root = root };
}

pub fn returns(self: *const Self, root: ir.BlockId) bool {
    const table = self.view();

    return ir.terminates(@import("read.zig").block(&table, root));
}

pub fn terminates(self: *const Self, values: []const ir.Statement) bool {
    if (values.len == 0) return false;

    return switch (values[values.len - 1]) {
        .result => true,
        .branch => |branch| self.returns(branch.yes) and self.returns(branch.no),
        .switch_stmt => |selection| blk: {
            if (!selection.exhaustive) break :blk false;

            for (selection.cases) |case| if (!self.returns(case.body)) {
                break :blk false;
            };

            break :blk true;
        },
        else => false,
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    inline for (@typeInfo(model.Table).@"struct".field_names) |name| @field(self, name).deinit(allocator);

    self.* = .{};
}
