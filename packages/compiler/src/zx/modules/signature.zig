const std = @import("std");
const zx = @import("zx");
const Types = @import("../analysis/types.zig");
const resolution = @import("../analysis/types/resolve.zig");
const External = @import("interface.zig").External;

pub const Result = struct { types: zx.ir.TypeTable, input_type: zx.ir.TypeId, output_type: zx.ir.TypeId };

pub fn resolve(allocator: std.mem.Allocator, entry: External, span: zx.Span, existing: *zx.ir.TypeStorage, shared: Types.Shared, reporter: *zx.Reporter) zx.Error!Result {
    if (@import("parser_options").generated_parser) {
        var scratch = std.heap.ArenaAllocator.init(allocator);

        defer scratch.deinit();

        const output = @import("generated_parser").execute(&scratch, &.{
            .source = entry.signature,
            .placement = null,
            .omit_tokens = true,
            .omit_comments = true,
        }) catch |err| switch (err) {
            error.OutOfMemory, error.Overflow => return error.OutOfMemory,
            else => return invalid(reporter, span),
        };

        if (output.diagnostic != null or output.body != null or output.imports.len != 0 or output.constants.len != 0) return invalid(reporter, span);

        var resolved = output.*;
        var type_order: std.meta.Child(@TypeOf(resolved.type_order)) = undefined;

        try @import("../frontend/retention/order.zig").fill(scratch.allocator(), resolved.types, &type_order);

        resolved.type_order = &type_order;

        const View = @import("type_views").Indexed(@TypeOf(&resolved));

        const view = View{
            .source = entry.signature,
            .storage = &resolved,
        };

        return analyze(allocator, view, span, existing, shared, reporter);
    }

    var parsed = try @import("../frontend/parse.zig").parse(allocator, entry.signature, entry.specifier);

    defer parsed.deinit();

    if (parsed.value == .diagnostic or parsed.value.parsed.ast.body != null or parsed.value.parsed.ast.imports.len != 0 or parsed.value.parsed.ast.constants.len != 0) return invalid(reporter, span);

    const view = @import("type_views").Native{ .items = parsed.value.parsed.ast.declarations };

    return analyze(allocator, view, span, existing, shared, reporter);
}

fn analyze(allocator: std.mem.Allocator, view: anytype, span: zx.Span, existing: *zx.ir.TypeStorage, shared: Types.Shared, reporter: *zx.Reporter) zx.Error!Result {
    var types = Types{ .allocator = allocator, .reporter = reporter, .declarations = &.{}, .shared = shared };

    types.items = existing.*;
    existing.* = .{};
    defer existing.* = types.items;

    try resolution.initialize(&types, view);

    const input_type = try resolution.named(&types, view, .{ .text = "Input", .span = span });
    const output_type = try resolution.named(&types, view, .{ .text = "Output", .span = span });

    return .{ .types = types.items.view(), .input_type = input_type, .output_type = output_type };
}

fn invalid(reporter: *zx.Reporter, span: zx.Span) zx.Error {
    return reporter.fail(.module, span, "a reviewed external signature must be a self-contained pure type module");
}
