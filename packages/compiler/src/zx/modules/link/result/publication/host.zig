const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Model = @import("../../../artifact/model.zig");
const Surface = @import("../../../artifact/surface.zig").Publication;
const verification = @import("../../../artifact/validation/view.zig");
const Retained = @import("../../artifact/binding/abi.zig").Retained;
const program = @import("../host.zig");
const destination = @import("../../signature/publication/destination.zig");
const rule = @import("generated_artifact_program_publication");
const Input = std.meta.Child(rule.Input);
const Store = std.meta.Child(@FieldType(Input, "store_source"));
const Destination = std.meta.Child(@FieldType(Input, "destination"));
const Empty = std.meta.Child(@FieldType(Input, "empty"));
const Entry = @typeInfo(@FieldType(Input, "retained")).optional.child;
const Verification = std.meta.Child(@FieldType(Input, "verification"));
const empty = destination.empty(Empty);

pub fn finish(allocator: std.mem.Allocator, temporary: std.mem.Allocator, module: *const Model.Module, function: ?Retained, state: verification.State, mapping: []const ir.TypeId) Model.Error!ir.Program {
    const source_stores = zx.columns.columns(Store, module.stores);
    var surface: Surface(std.meta.Child(@FieldType(Input, "surface"))) = undefined;

    surface.init(module.exports, module.constant_exports, .{ .mapped = mapping });
    errdefer surface.release(allocator);

    var target: destination.View(Destination) = undefined;

    target.init(&allocator, state.functions);

    var arena = std.heap.ArenaAllocator.init(temporary);

    defer arena.deinit();

    const scratch = arena.allocator();
    var scope: zx.memory.ArenaScope = .{ .active = allocator };
    var validation: verification.View(Verification) = undefined;

    validation.init(state, &surface, &scope, &scratch, &allocator);

    const request: Input = .{
        .store_source = &source_stores,
        .surface = &surface.input,
        .path = module.path,
        .destination = &target.input,
        .empty = &empty,
        .retained = if (function) |value| zx.columns.pointer(Entry, value) else null,
        .verification = &validation.input,
    };

    const outcome = rule.executeIn(scope.allocator(), &request) catch |err| return verification.failure(&scope, scratch, err);
    const published = outcome orelse return error.InvalidModule;

    if (!published.valid) return error.InvalidIr;

    const linked_tables: program.Tables = .{
        .types = state.types.view(),
        .functions = state.functions.view(),
        .native_modules = state.native_modules.*,
    };

    return program.fromPublication(published.path, published, linked_tables, surface.exports(), surface.constants());
}
