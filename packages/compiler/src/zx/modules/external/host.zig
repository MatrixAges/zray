const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Project = @import("../project.zig").Project;
const Origins = @import("../nominal_origins.zig");
const External = @import("../interface.zig").External;
const FunctionImport = @import("../function_import.zig");
const generated = @import("generated_external_interface_delivery");
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

    types.init(options);

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

    if (output.diagnostic.message.len != 0) {
        const message = try allocator.dupe(u8, output.diagnostic.message);

        if (output.publication) |plan| types.commit(plan) catch |err| {
            allocator.free(message);

            return err;
        };

        return project.reporter.fail(
            std.meta.stringToEnum(@FieldType(zx.Diagnostic, "code"), output.diagnostic.code) orelse unreachable,
            .{ .start = @intCast(output.diagnostic.start), .end = @intCast(output.diagnostic.end) },
            message,
        );
    }

    const prepared = output.prepared.?;
    const external = prepared.function.external.?;
    const file_name = try allocator.dupe(u8, prepared.function.file);

    errdefer allocator.free(file_name);

    const members = try dupeTexts(allocator, external.members);

    errdefer freeTexts(allocator, members);

    const errors = if (external.errors) |items| try dupeTexts(allocator, items) else null;

    errdefer if (errors) |items| freeTexts(allocator, items);

    const export_name = if (external.export_name) |text| try allocator.dupe(u8, text) else null;

    errdefer if (export_name) |name| allocator.free(name);

    try project.functions.reserve(allocator, 1);
    if (output.publication) |plan| try types.commit(plan);

    project.functions.appendSignatureAssumeCapacity(.{
        .file_name = file_name,
        .input_type = @fromBackingInt(prepared.function.ports.input),
        .output_type = @fromBackingInt(prepared.function.ports.output),
        .output_ownership = .borrowed,
        .external = .{
            .module = @fromBackingInt(prepared.function.ports.native_module.?),
            .member = members,
            .export_name = export_name,
            .allocator_argument = prepared.flags.allocator_argument,
            .io_argument = prepared.flags.io_argument,
            .process_argument = prepared.flags.process_argument,
            .expand_tuple = prepared.flags.expand_tuple,
            .fallible = prepared.flags.fallible,
            .errors = errors,
            .concurrent = prepared.flags.concurrent,
        },
    });

    return .{
        .name = "",
        .id = @fromBackingInt(@as(u32, @intCast(id))),
        .input_type = @fromBackingInt(output.input_type),
        .output_type = @fromBackingInt(output.output_type),
    };
}

fn dupeTexts(allocator: std.mem.Allocator, source: []const []const u8) std.mem.Allocator.Error![]const []const u8 {
    const copy = try allocator.alloc([]const u8, source.len);

    errdefer allocator.free(copy);

    var count: usize = 0;

    errdefer for (copy[0..count]) |text| allocator.free(text);

    for (source, copy) |item, *slot| {
        slot.* = try allocator.dupe(u8, item);
        count += 1;
    }

    return copy;
}

fn freeTexts(allocator: std.mem.Allocator, source: []const []const u8) void {
    for (source) |text| allocator.free(text);

    allocator.free(source);
}
