const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const FunctionImport = @import("../../../function_import.zig");
const export_rows = @import("../../../../ir/canonical/validation/names/view.zig");
const finalize = @import("generated_native_module_finalize");
const publication = @import("generated_native_members_publication");
const NativeInput = std.meta.Child(publication.Input);
const Rows = std.meta.Child(@FieldType(NativeInput, "rows"));
const NativeMember = std.meta.Elem(@FieldType(std.meta.Child(@import("generated_native_interface").Output), "members"));

pub const Staged = struct {
    members: []const FunctionImport = &.{},
    namespace: ?[]const []const u8 = null,
};

pub fn Stage(comptime Input: type) type {
    const Destination = std.meta.Child(@FieldType(Input, "destination"));
    const FunctionRow = std.meta.Child(@typeInfo(@FieldType(Destination, "shape")).optional.child);
    const MemberTarget = std.meta.Child(@FieldType(Input, "members"));

    return struct {
        const Self = @This();
        slots: [@typeInfo(FunctionRow).@"struct".field_names.len]*anyopaque,
        columns: zx.memory.ColumnSet,
        destination: Destination,
        output: zx.memory.RowOutput(FunctionImport, MemberTarget, .{
            .name = &.{"name"},
            .namespace = &.{"namespace"},
            .id = &.{"id"},
            .input_type = &.{"input_type"},
            .output_type = &.{"output_type"},
            .intrinsic = &.{"intrinsic"},
        }),
        pub fn init(self: *Self, resource: *const std.mem.Allocator, functions: *ir.FunctionStorage) void {
            self.slots = zx.memory.bindColumnSet(FunctionRow, true, functions);
            self.columns = &self.slots;

            self.destination = .{
                .storage = @ptrCast(&self.columns),
                .shape = null,
                .maximum_count = std.math.maxInt(u32),
                .resource = @ptrCast(resource),
            };

            self.output.init();
        }

        pub fn members(self: *const Self) []const FunctionImport {
            return self.output.rows();
        }

        pub fn empty(comptime T: type) T {
            return .{
                .symbols = @ptrCast(&ir.FunctionStorage.empty_symbols),
                .expressions = @ptrCast(&ir.FunctionStorage.empty_expressions),
                .contracts = @ptrCast(&ir.FunctionStorage.empty_contracts),
                .control = @ptrCast((ir.ControlBody{}).control),
                .stores = @ptrCast(&ir.FunctionStorage.empty_stores),
            };
        }
    };
}

/// Fills rows while the project retains control of when their lengths become visible.
pub fn stageNative(allocator: std.mem.Allocator, storage: *ir.FunctionStorage, source: []const NativeMember, path: []const u8, namespace: []const []const u8, module: ir.NativeModuleId) std.mem.Allocator.Error!Staged {
    if (source.len == 0) return .{};

    var stage: Stage(NativeInput) = undefined;

    stage.init(&allocator, storage);

    const input: NativeInput = .{
        .rows = &.{ .fresh = zx.columns.slice(@FieldType(Rows, "fresh"), source), .cached = null, .count = source.len },
        .owner = &.{ .path = path, .namespace = namespace, .module = @backingInt(module) },
        .destination = &stage.destination,
        .members = &stage.output.view,
        .member_storage = @ptrCast(&stage.output.buffer),
        .first = storage.count(),
        .empty = &Stage(NativeInput).empty(std.meta.Child(@FieldType(NativeInput, "empty"))),
    };

    const owned_namespace = publication.executeIn(allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    return .{ .members = stage.members(), .namespace = owned_namespace };
}

pub fn finalizeNative(allocator: std.mem.Allocator, modules: *ir.NativeModuleStorage, functions: *ir.FunctionStorage, module: ir.NativeModuleId, loaded: @import("../../../native.zig").Result, original: []const []const u8) std.mem.Allocator.Error!void {
    const Input = std.meta.Child(finalize.Input);
    const Exports = std.meta.Child(@FieldType(Input, "exports"));
    const rows = export_rows.borrow(loaded.exports);
    const view = export_rows.view(std.meta.Child(@FieldType(Exports, "source")), &rows);
    const length_slots = zx.memory.borrowColumnLengths(functions);
    const lengths: zx.memory.ColumnLengths = &length_slots;
    var names: [][]const u8 = &.{};
    var ids: []u32 = &.{};

    errdefer {
        allocator.free(ids);
        allocator.free(names);
    }

    const namespace: std.meta.Child(@FieldType(Input, "namespace")) = .{ .published = loaded.namespace, .original = original };

    const exports: Exports = .{
        .source = &view,
        .names = @ptrCast(&names),
        .ids = @ptrCast(&ids),
    };

    const destination: std.meta.Child(@FieldType(Input, "destination")) = .{
        .module = @backingInt(module),
        .namespaces = @ptrCast(&modules.type_namespaces.items),
        .names = @ptrCast(&modules.type_names.items),
        .ids = @ptrCast(&modules.type_ids.items),
        .functions = @ptrCast(&lengths),
        .member_count = loaded.members.len,
    };

    const input: Input = .{ .namespace = &namespace, .exports = &exports, .destination = &destination };

    const installed = finalize.executeIn(allocator, &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.IndexOutOfBounds => unreachable,
    };

    if (!installed) return error.OutOfMemory;
}
