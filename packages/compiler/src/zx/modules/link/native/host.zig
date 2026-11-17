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

pub const View = struct {
    input: Input,
    base: Table,
    rows: Table,
    slots: [@typeInfo(Row).@"struct".field_names.len]*anyopaque,
    columns: zx.memory.ColumnSet,
    ids: []u32,
    plan: Plan,
    publication: Publication,
    destination: Destination,
    pub fn init(self: *View, allocator: *const std.mem.Allocator, modules: *ir.NativeModuleStorage, source: ir.NativeModuleTable, types: []const u32, mapping: ?*[]?ir.NativeModuleId) void {
        self.rows = zx.columns.columns(Table, source);
        self.slots = zx.memory.bindColumnSet(Row, true, modules);
        self.columns = &self.slots;
        self.ids = &.{};

        if (mapping) |target| {
            self.base = zx.columns.columns(Table, modules.view());
            self.plan = .{ .base = &self.base, .source = &self.rows, .types = types, .target = @ptrCast(target) };
        }

        self.destination = .{
            .storage = @ptrCast(&self.columns),
            .shape = null,
            .resource = @ptrCast(allocator),
            .ids = @ptrCast(&self.ids),
        };

        self.publication = .{ .source = &self.rows, .mapping = types, .destination = &self.destination };
        self.input = .{ .plan = if (mapping != null) &self.plan else null, .publication = &self.publication };
    }
};

pub fn append(temporary: std.mem.Allocator, allocator: std.mem.Allocator, modules: *ir.NativeModuleStorage, source: ir.NativeModuleTable, types: []const u32) std.mem.Allocator.Error!void {
    if (source.count() == 0) return;

    publish(temporary, allocator, modules, source, types, null) catch return error.OutOfMemory;
}

pub fn link(temporary: std.mem.Allocator, allocator: std.mem.Allocator, modules: *ir.NativeModuleStorage, source: ir.NativeModuleTable, mapping: []?ir.NativeModuleId, types: []const u32) Error!void {
    return publish(temporary, allocator, modules, source, types, mapping);
}

fn publish(temporary: std.mem.Allocator, allocator: std.mem.Allocator, modules: *ir.NativeModuleStorage, source: ir.NativeModuleTable, types: []const u32, mapping: ?[]?ir.NativeModuleId) Error!void {
    var view: View = undefined;
    var target: []?ir.NativeModuleId = mapping orelse &.{};

    view.init(&allocator, modules, source, types, if (mapping != null) &target else null);

    const failure = rule.executeIn(temporary, &view.input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    if (failure) |status| return switch (status) {
        .Conflict => error.ConflictingInterface,
        .Full => error.OutOfMemory,
        else => error.InvalidModule,
    };
}
