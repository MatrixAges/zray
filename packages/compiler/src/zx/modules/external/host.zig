const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Project = @import("../project.zig").Project;
const Origins = @import("../nominal_origins.zig");
const External = @import("../interface.zig").External;
const FunctionImport = @import("../function_import.zig");
const generated = @import("generated_external_interface_delivery");
const destination = @import("../link/signature/publication/destination.zig");
const TypeTail = @import("../../analysis/semantic/merging/publication/view.zig");
const Input = std.meta.Child(generated.Input);
const Analysis = std.meta.Child(@FieldType(Input, "analysis"));

pub fn load(project: *Project, entry: *const External, module: ir.NativeModuleId, span: zx.Span) zx.Error!FunctionImport {
    const allocator = project.allocator;
    var scratch = std.heap.ArenaAllocator.init(allocator);

    defer scratch.deinit();

    const offsets = TypeTail.offsets(&project.types);
    const options: TypeTail.Options = .{ .allocator = allocator, .payload = allocator, .types = &project.types, .origins = &project.nominal_origins.items, .offsets = &offsets };
    var types: TypeTail = undefined;

    types.init(&options, .{}, Origins.Table{});

    errdefer types.release();

    var view: destination.View(std.meta.Child(@FieldType(Input, "destination"))) = undefined;

    view.init(&allocator, &project.functions);

    const id = project.functions.count();
    const implementation = entry.implementation;

    const request: Input = .{
        .analysis = &.{
            .bytes = entry.signature,
            .type_base = &ir.TypeTable.borrow(std.meta.Child(@FieldType(Analysis, "type_base")), project.types.view()),
            .nominal_base = &Origins.Table.borrow(std.meta.Child(@FieldType(Analysis, "nominal_base")), project.nominal_origins.items.view()),
            .span = &.{ .start = span.start, .end = span.end },
            .member = implementation.member,
        },
        .identity = entry.identity,
        .types = zx.columns.pointer(@FieldType(Input, "types"), @as(*const TypeTail.Target, &types.target)),
        .destination = &view.input,
        .empty = &destination.empty(std.meta.Child(@FieldType(Input, "empty"))),
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
    };

    const output = generated.executeIn(scratch.allocator(), &request) catch |err| switch (err) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => return project.reporter.fail(.contract, span, try std.fmt.allocPrint(allocator, "internal compiler error: generated external delivery failed with {s}", .{@errorName(err)})),
    };

    if (output.diagnostic.message.len != 0) return project.reporter.fail(
        std.meta.stringToEnum(@FieldType(zx.Diagnostic, "code"), output.diagnostic.code) orelse unreachable,
        .{ .start = @intCast(output.diagnostic.start), .end = @intCast(output.diagnostic.end) },
        try allocator.dupe(u8, output.diagnostic.message),
    );

    return .{
        .name = "",
        .id = @fromBackingInt(@as(u32, @intCast(id))),
        .input_type = @fromBackingInt(output.input_type),
        .output_type = @fromBackingInt(output.output_type),
    };
}
