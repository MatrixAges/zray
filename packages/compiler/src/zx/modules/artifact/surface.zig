const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Binding = @import("../function_import.zig");
const Nodes = @import("nodes.zig");
const remap = @import("nodes/remap.zig");
const Error = @import("model.zig").Error;
const names = @import("../../ir/canonical/validation/names/view.zig");
const constants = @import("generated_artifact_surface_constants");
const memory = zx.memory;
const constant_value = @import("../../analysis/constants/input.zig");
const ConstantRows = @import("../../analysis/constants/columns.zig").Rows;
const ConstantInput = std.meta.Child(constants.Input);
pub const Mapping = std.meta.Child(@FieldType(ConstantInput, "types"));

pub const Surface = struct {
    exports: []const ir.Export = &.{},
    constant_exports: []const ir.Constant = &.{},
    constant_imports: []const ir.Constant = &.{},
    type_imports: []const ir.Export = &.{},
    function_imports: []const Binding = &.{},
    members: []const Binding = &.{},
};

pub fn copyConstants(allocator: std.mem.Allocator, source: []const ir.Constant, types: *const Mapping) Error![]const ir.Constant {
    if (source.len == 0) return &.{};

    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const rows = ConstantRows.borrow(source);

    const input: ConstantInput = .{
        .source = &rows.view(std.meta.Child(@FieldType(ConstantInput, "source"))),
        .types = types,
    };

    const plan = zx.columns.invoke(constants.executeValue, arena.allocator(), &input) catch |err| return failure(err);

    return ownConstants(allocator, plan);
}

pub fn ownConstants(allocator: std.mem.Allocator, rows: anytype) std.mem.Allocator.Error![]ir.Constant {
    const result = try allocator.alloc(ir.Constant, rows.len);
    var written: usize = 0;

    errdefer {
        releaseConstants(allocator, result[0..written]);
        allocator.free(result);
    }

    for (rows, result) |row, *slot| {
        const name = try allocator.dupe(u8, row.name);

        errdefer allocator.free(name);

        slot.* = .{
            .name = name,
            .type_id = @fromBackingInt(row.value.type_id),
            .value = try constant_value.own(allocator, row.value),
        };

        written += 1;
    }

    return result;
}

fn releaseConstants(allocator: std.mem.Allocator, rows: []const ir.Constant) void {
    for (rows) |row| {
        allocator.free(row.name);

        if (row.value == .string) allocator.free(row.value.string);
    }
}

const ConstantOutput = memory.RowOutput(ir.Constant, struct {
    names: *anyopaque,
    types: *anyopaque,
    values: *anyopaque,
}, .{ .names = &.{"name"}, .types = &.{"type_id"}, .values = &.{"value"} });

pub fn Publication(comptime Input: type) type {
    const Exports = std.meta.Child(@FieldType(Input, "exports"));
    const Constants = std.meta.Child(@FieldType(Input, "constants"));

    return struct {
        const Self = @This();
        export_rows: names.Rows,
        export_source: Exports,
        export_target: []ir.Export,
        export_count: usize,
        written: usize,
        constant_rows: ConstantRows,
        constant_source: Constants,
        constant_output: ConstantOutput,
        mapping: std.meta.Child(@FieldType(Input, "types")),
        input: Input,
        pub fn init(self: *Self, export_rows: []const ir.Export, constant_rows: []const ir.Constant, types: Nodes.TypeMap) void {
            self.export_rows = names.borrow(export_rows);
            self.export_source = names.view(Exports, &self.export_rows);
            self.export_target = &.{};
            self.export_count = export_rows.len;
            self.written = 0;
            self.constant_rows = ConstantRows.borrow(constant_rows);
            self.constant_source = self.constant_rows.view(Constants);

            self.constant_output.init();

            self.mapping = remap.typeMapping(@TypeOf(self.mapping), types);

            self.input = .{
                .types = &self.mapping,
                .exports = &self.export_source,
                .constants = &self.constant_source,
            };
        }
        pub fn publishExport(self: *Self, allocator: std.mem.Allocator, entry: anytype) std.mem.Allocator.Error!void {
            if (entry.constants) |rows| {
                self.constant_output.bind(try ownConstants(allocator, rows));

                return;
            }

            if (self.export_target.len == 0) self.export_target = try allocator.alloc(ir.Export, self.export_count);

            self.export_target[@intCast(entry.row)] = .{ .name = try allocator.dupe(u8, entry.name), .type_id = @fromBackingInt(entry.id) };

            self.written += 1;
        }

        const Host = struct {
            surface: *Self,
            allocator: std.mem.Allocator,
            pub fn commit(self: *Host, pending: anytype) std.mem.Allocator.Error!void {
                if (pending.store_0) |row| try self.surface.publishExport(self.allocator, row);
            }
        };
        pub fn host(self: *Self, allocator: std.mem.Allocator) Host {
            return .{ .surface = self, .allocator = allocator };
        }
        pub fn release(self: *const Self, allocator: std.mem.Allocator) void {
            for (self.export_target[0..self.written]) |item| allocator.free(item.name);

            allocator.free(self.export_target);
            releaseConstants(allocator, self.constant_output.rows());
            allocator.free(self.constant_output.rows());
        }

        pub fn exports(self: *const Self) []const ir.Export {
            return self.export_target;
        }
        pub fn constants(self: *const Self) []const ir.Constant {
            return self.constant_output.rows();
        }
    };
}

pub fn BindingPublication(comptime Input: type) type {
    const Source = std.meta.Child(@FieldType(Input, "source"));
    const Map = std.meta.Child(@FieldType(Input, "types"));

    return struct {
        const Self = @This();
        source: Source,
        columns: Binding.Columns,
        types: Map,
        functions: Map,
        input: Input,
        pub fn init(self: *Self, source: []const Binding, nodes: *const Nodes) void {
            self.columns = Binding.borrowColumns(source);
            self.types = remap.typeMapping(Map, nodes.types);
            self.functions = remap.idMapping(Map, nodes.functions);
            self.source = self.columns.bind(Source);

            self.input = .{
                .source = &self.source,
                .types = &self.types,
                .functions = &self.functions,
            };
        }
    };
}

fn failure(err: anyerror) Error {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidModule;
}
