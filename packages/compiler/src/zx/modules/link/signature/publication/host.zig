const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const FunctionImport = @import("../../../function_import.zig");
const export_rows = @import("../../../../ir/canonical/validation/names/view.zig");
const finalize = @import("generated_native_module_finalize");
const publication = @import("generated_native_members_publication");
const function_target = @import("destination.zig");
const native_bindings = @import("native_bindings.zig");
const NativeInput = std.meta.Child(publication.Input);
const Rows = std.meta.Child(@FieldType(NativeInput, "rows"));
const NativeMember = std.meta.Elem(@FieldType(std.meta.Child(@import("generated_native_interface").Output), "members"));

pub const Staged = struct {
    members: []const FunctionImport = &.{},
    namespace: ?[]const []const u8 = null,
};

pub fn Stage(comptime Input: type) type {
    const Destination = std.meta.Child(@FieldType(Input, "destination"));
    const MemberTarget = std.meta.Child(@FieldType(Input, "members"));

    return struct {
        const Self = @This();

        functions: function_target.View(Destination),
        output: zx.memory.RowOutput(FunctionImport, MemberTarget, .{
            .name = &.{"name"},
            .namespace = &.{"namespace"},
            .id = &.{"id"},
            .input_type = &.{"input_type"},
            .output_type = &.{"output_type"},
            .intrinsic = &.{"intrinsic"},
        }),
        pub fn init(self: *Self, resource: *const std.mem.Allocator, functions: *ir.FunctionStorage) void {
            self.functions.init(resource, functions);
            self.output.init();
        }

        pub fn members(self: *const Self) []const FunctionImport {
            return self.output.rows();
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
        .destination = &stage.functions.input,
        .members = &stage.output.view,
        .member_storage = @ptrCast(&stage.output.buffer),
        .first = storage.count(),
        .empty = &function_target.empty(std.meta.Child(@FieldType(NativeInput, "empty"))),
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
    const Destination = std.meta.Child(@FieldType(Input, "destination"));
    var view: native_bindings.View(Exports, Destination) = undefined;

    view.init(modules, functions, module, &rows, rows.len);

    view.destination.member_count = loaded.members.len;

    errdefer view.release(allocator);

    const namespace: std.meta.Child(@FieldType(Input, "namespace")) = .{ .published = loaded.namespace, .original = original };
    const input: Input = .{ .namespace = &namespace, .exports = &view.exports, .destination = &view.destination };

    const installed = finalize.executeIn(allocator, &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.IndexOutOfBounds => unreachable,
    };

    if (!installed) return error.OutOfMemory;
}
