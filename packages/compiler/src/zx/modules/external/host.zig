const std = @import("std");
const zx = @import("zx");
const Types = @import("../../analysis/types.zig");
const Origins = @import("../nominal_origins.zig");
const External = @import("../interface.zig").External;
const FunctionImport = @import("../function_import.zig");
const generated = @import("generated_external");
const delivery = @import("generated_external_interface_delivery");
const destination = @import("../link/signature/publication/destination.zig");
const publication = @import("../../analysis/semantic/merging/commit.zig");
const Input = std.meta.Child(generated.Input);
const Delivery = std.meta.Child(delivery.Input);
const Record = std.meta.Child(@FieldType(Delivery, "record"));

pub fn load(allocator: std.mem.Allocator, entry: External, module: zx.ir.NativeModuleId, span: zx.Span, existing: *zx.ir.TypeStorage, shared: Types.Shared, functions: *zx.ir.FunctionStorage, reporter: *zx.Reporter) zx.Error!FunctionImport {
    var scratch = std.heap.ArenaAllocator.init(allocator);

    defer scratch.deinit();

    const base = zx.ir.TypeTable.borrow(std.meta.Child(@FieldType(Input, "type_base")), existing.view());
    const origins = Origins.Table.borrow(std.meta.Child(@FieldType(Input, "nominal_base")), shared.origins.items.view());

    const origin: std.meta.Child(@FieldType(Input, "nominal_origin")) = .{
        .kind = switch (shared.origin) {
            .source => 0,
            .native => 1,
            .external => 2,
        },
        .owner = switch (shared.origin) {
            .source, .native => |name| name,
            .external => |value| value.module,
        },
        .member = if (shared.origin == .external) shared.origin.external.member else "",
    };

    const location: std.meta.Child(@FieldType(Input, "span")) = .{ .start = span.start, .end = span.end };
    const implementation = entry.implementation;

    const input = Input{
        .bytes = entry.signature,
        .type_base = &base,
        .nominal_base = &origins,
        .nominal_origin = &origin,
        .span = &location,
        .expand_tuple = implementation.expand_tuple,
        .fallible = implementation.fallible,
        .errors = implementation.errors,
        .member = implementation.member,
    };

    const output = generated.execute(&scratch, &input) catch |err| switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => return reporter.fail(.contract, span, try std.fmt.allocPrint(allocator, "internal compiler error: generated external loading failed with {s}", .{@errorName(err)})),
    };

    const id: zx.ir.FunctionId = @fromBackingInt(@as(u32, @intCast(functions.count())));
    const target = publication.Interface.init(allocator, existing, &shared.origins.items, output.type_delta, output.nominal_delta);
    var view: destination.View(std.meta.Child(@FieldType(Delivery, "destination"))) = undefined;

    view.init(&allocator, functions);

    const request: Delivery = .{
        .types = @ptrCast(&target),
        .publish_types = output.publish,
        .valid = output.diagnostic.message.len == 0,
        .destination = &view.input,
        .empty = &destination.empty(std.meta.Child(@FieldType(Delivery, "empty"))),
        .record = &Record{
            .members = zx.columns.slice(@FieldType(Record, "members"), output.members),
            .input_type = output.input_type,
            .output_type = output.output_type,
            .implementation = &.{
                .specifier = entry.specifier,
                .module = @backingInt(module),
                .member = implementation.member,
                .export_name = entry.export_name,
                .allocator_argument = implementation.allocator_argument,
                .io_argument = implementation.io_argument,
                .process_argument = implementation.process_argument,
                .expand_tuple = implementation.expand_tuple,
                .fallible = implementation.fallible,
                .errors = implementation.errors,
                .concurrent = implementation.concurrent,
            },
        },
    };

    delivery.executeIn(allocator, &request) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => return reporter.fail(.contract, span, try std.fmt.allocPrint(allocator, "internal compiler error: generated external delivery failed with {s}", .{@errorName(err)})),
    };

    if (output.diagnostic.message.len != 0) return reporter.fail(
        std.meta.stringToEnum(@FieldType(zx.Diagnostic, "code"), output.diagnostic.code) orelse unreachable,
        .{ .start = @intCast(output.diagnostic.start), .end = @intCast(output.diagnostic.end) },
        try allocator.dupe(u8, output.diagnostic.message),
    );

    return .{
        .name = "",
        .id = id,
        .input_type = @fromBackingInt(output.input_type),
        .output_type = @fromBackingInt(output.output_type),
    };
}
