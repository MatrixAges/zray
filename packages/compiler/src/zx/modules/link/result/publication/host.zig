const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Nodes = @import("../../../artifact/nodes.zig");
const Model = @import("../../../artifact/model.zig");
const Surface = @import("../../../artifact/surface.zig").Publication;
const program = @import("../host.zig");
const rule = @import("generated_artifact_program_publication");
const Input = std.meta.Child(rule.Input);
const Store = std.meta.Child(@FieldType(Input, "store_source"));
const Forward = std.meta.Child(@typeInfo(@FieldType(Input, "forward")).optional.child);
const Symbols = std.meta.Child(@FieldType(Forward, "symbols"));

pub fn finish(allocator: std.mem.Allocator, temporary: std.mem.Allocator, module: *const Model.Module, function: ?*const Nodes.FunctionEntry, tables: program.Tables, functions: *ir.FunctionStorage, mapping: []const ir.TypeId) Model.Error!ir.Program {
    const source_stores = zx.columns.columns(Store, module.stores);
    const body = if (function) |found| &found.body else null;
    const recursive = if (function) |found| found.recursive else null;
    var symbols: Symbols = undefined;
    var forward: Forward = undefined;

    if (recursive) |id| {
        const entry = function.?;

        try functions.reserve(allocator, 1);

        functions.appendOwnedAssumeCapacity(entry.body, entry.descriptors.?);

        symbols = zx.columns.columns(Symbols, body.?.symbols);

        forward = .{
            .symbols = &symbols,
            .input_type = @backingInt(body.?.input_type),
            .output_type = @backingInt(body.?.output_type),
            .function_id = @backingInt(id),
        };
    }

    var surface: Surface(std.meta.Child(@FieldType(Input, "surface"))) = undefined;

    surface.init(module.exports, module.constant_exports, .{ .mapped = mapping });
    errdefer surface.release(allocator);

    const request: Input = .{
        .store_source = &source_stores,
        .surface = &surface.input,
        .path = module.path,
        .forward = if (recursive != null) &forward else null,
    };

    const outcome = zx.columns.invoke(rule.executeValue, allocator, &request) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    const published = outcome orelse return error.InvalidModule;
    var linked = tables;
    linked.functions = functions.view();
    const stores = zx.columns.view(ir.StoreTable, published.stores);
    var assembled = program.program(published.path, body, linked, stores, surface.exports(), surface.constants());

    if (published.wrapper) |wrapper| try @import("../../../forward_entry/host.zig").install(allocator, &assembled, wrapper);
    if (try @import("../../../../ir/validate.zig").validate(temporary, assembled) != null) return error.InvalidIr;

    return assembled;
}
