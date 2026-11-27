const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Error = @import("../../artifact/model.zig").Error || error{ConflictingInterface};
const rule = @import("generated_native_link");
pub const Input = std.meta.Child(rule.Input);
const Plan = std.meta.Child(@typeInfo(@FieldType(Input, "plan")).optional.child);
const Publication = std.meta.Child(@FieldType(Input, "publication"));
const Destination = std.meta.Child(@FieldType(Publication, "destination"));
const Row = std.meta.Child(std.meta.Child(@FieldType(Destination, "shape")));
const Table = std.meta.Child(@FieldType(Publication, "source"));
const strings = @import("../../compiled/host/native.zig").strings;

pub const View = struct {
    input: Input,
    base: Table,
    rows: Table,
    slots: [@typeInfo(Row).@"struct".field_names.len]*anyopaque,
    columns: zx.memory.ColumnSet,
    modules: *ir.NativeModuleStorage,
    allocator: std.mem.Allocator,
    plan: Plan,
    publication: Publication,
    destination: Destination,
    pub fn init(self: *View, allocator: *const std.mem.Allocator, modules: *ir.NativeModuleStorage, source: ir.NativeModuleTable, types: []const u32, plan: bool) void {
        self.rows = zx.columns.columns(Table, source);
        self.slots = zx.memory.bindColumnSet(Row, true, modules);
        self.columns = &self.slots;
        self.modules = modules;
        self.allocator = allocator.*;

        if (plan) {
            self.base = zx.columns.columns(Table, modules.view());
            self.plan = .{ .base = &self.base, .source = &self.rows, .types = types };
        }

        self.destination = .{
            .storage = @ptrCast(&self.columns),
            .shape = null,
            .resource = @ptrCast(allocator),
        };

        self.publication = .{ .source = &self.rows, .mapping = types, .rows = null, .destination = &self.destination };
        self.input = .{ .plan = if (plan) &self.plan else null, .publication = &self.publication };
    }
    pub fn commit(self: *View, pending: anytype) std.mem.Allocator.Error!void {
        if (pending.store_0) |row| try self.publish(row);
    }
    pub fn publish(self: *View, row: anytype) std.mem.Allocator.Error!void {
        const allocator = self.allocator;
        const specifier = try allocator.dupe(u8, row.specifier);

        errdefer allocator.free(specifier);

        const identity = if (row.identity) |text| try allocator.dupe(u8, text) else null;

        errdefer if (identity) |text| allocator.free(text);

        const import_name = try allocator.dupe(u8, row.import_name);

        errdefer allocator.free(import_name);

        const namespace = try strings(allocator, row.namespace);

        errdefer releaseStrings(allocator, namespace);

        const names = try strings(allocator, row.names);

        errdefer releaseStrings(allocator, names);

        const ids = try allocator.dupe(u32, row.ids);

        errdefer allocator.free(ids);

        try self.modules.append(allocator, .{
            .specifier = specifier,
            .identity = identity,
            .import_name = import_name,
            .type_namespace = namespace,
            .types = .{ .names = names, .type_ids = ids },
        });
    }
};

fn releaseStrings(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |text| allocator.free(text);

    allocator.free(values);
}

pub fn link(temporary: std.mem.Allocator, allocator: std.mem.Allocator, modules: *ir.NativeModuleStorage, source: ir.NativeModuleTable, mapping: []?ir.NativeModuleId, types: []const u32) Error!void {
    var view: View = undefined;
    var arena = std.heap.ArenaAllocator.init(temporary);

    defer arena.deinit();
    view.init(&allocator, modules, source, types, true);

    const result = rule.executeIn(arena.allocator(), &view.input, &view) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    if (result.failure) |status| return switch (status) {
        .Conflict => error.ConflictingInterface,
        .Full => error.OutOfMemory,
        else => error.InvalidModule,
    };

    @memcpy(@as([]?u32, @ptrCast(mapping)), result.ids);
}
