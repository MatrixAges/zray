const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const FunctionImport = @import("../../../function_import.zig");
const export_rows = @import("../../../../ir/canonical/validation/names/view.zig");
const finalize = @import("generated_native_module_finalize");
const function_target = @import("destination.zig");
const native_bindings = @import("native_bindings.zig");

pub fn Stage(comptime Input: type) type {
    const Destination = std.meta.Child(@FieldType(Input, "destination"));
    const MemberTarget = std.meta.Child(@FieldType(Input, "members"));

    return struct {
        const Self = @This();

        functions: function_target.View(Destination),
        output: FunctionImport.Output(MemberTarget),
        pub fn init(self: *Self, resource: *const std.mem.Allocator, functions: *ir.FunctionStorage) void {
            self.functions.init(resource, functions);
            self.output.init();
        }

        pub fn members(self: *const Self) []const FunctionImport {
            return self.output.rows();
        }
    };
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
