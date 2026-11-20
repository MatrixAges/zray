const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Model = @import("../../../artifact/model.zig");
const Surface = @import("../../../artifact/surface.zig").Publication;
const Retained = @import("../../artifact/binding/abi.zig").Retained;
const program = @import("../host.zig");
const destination = @import("../../signature/publication/destination.zig");
const rule = @import("generated_artifact_program_publication");
const Input = std.meta.Child(rule.Input);
const Store = std.meta.Child(@FieldType(Input, "store_source"));
const Destination = std.meta.Child(@FieldType(Input, "destination"));
const Empty = std.meta.Child(@FieldType(Input, "empty"));
const Entry = @typeInfo(@FieldType(Input, "retained")).optional.child;

pub fn finish(allocator: std.mem.Allocator, module: *const Model.Module, function: ?Retained, tables: program.Tables, functions: *ir.FunctionStorage, mapping: []const ir.TypeId) Model.Error!ir.Program {
    const source_stores = zx.columns.columns(Store, module.stores);
    var surface: Surface(std.meta.Child(@FieldType(Input, "surface"))) = undefined;

    surface.init(module.exports, module.constant_exports, .{ .mapped = mapping });
    errdefer surface.release(allocator);

    var target: destination.View(Destination) = undefined;

    target.init(&allocator, functions);

    const request: Input = .{
        .store_source = &source_stores,
        .surface = &surface.input,
        .path = module.path,
        .destination = &target.input,
        .empty = &destination.empty(Empty),
        .retained = if (function) |value| zx.columns.pointer(Entry, value) else null,
    };

    const outcome = rule.executeIn(allocator, &request) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    const published = outcome orelse return error.InvalidModule;

    const linked_tables: program.Tables = .{
        .types = tables.types,
        .functions = functions.view(),
        .native_modules = tables.native_modules,
    };

    return program.fromPublication(published.path, published, linked_tables, surface.exports(), surface.constants());
}
