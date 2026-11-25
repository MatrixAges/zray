const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Context = @import("context.zig");
const publication = @import("../../publication/host.zig");
const model = @import("model.zig");
const interface = @import("../../publication/interface.zig");

const Frame = struct {
    analyzer: *Context,
    output: *const model.Output,
    exports: []const ir.Export = &.{},
    constants: []const ir.Constant = &.{},
    fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn apply(analyzer: *Context, mode: @FieldType(model.Context, "mode"), output: *const model.Output, file_name: []const u8) zx.Error!ir.Program {
    const entry = @import("generated_analysis_publish_module");
    const Input = std.meta.Child(entry.Input);
    var frame: Frame = .{ .analyzer = analyzer, .output = output };

    const input: Input = .{
        .analysis = zx.columns.pointer(@FieldType(Input, "analysis"), output),
        .publication = @ptrCast(&frame),
        .mode = @fromBackingInt(@backingInt(mode)),
        .file_name = file_name,
        .borrow_body = analyzer.body_scratch != null,
    };

    const published = zx.columns.invoke(entry.executeValue, analyzer.allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    const body = publication.bodyView(published.body);

    return .{
        .file_name = published.file_name,
        .types = if (analyzer.body_scratch == null) analyzer.types.view() else .{},
        .input_type = @fromBackingInt(output.input_type),
        .output_type = @fromBackingInt(output.output_type),
        .output_ownership = switch (output.output_ownership) {
            .Copy => .copy,
            .Borrowed => .borrowed,
            .Owned => .owned,
        },
        .symbols = body.symbols,
        .expressions = body.expressions,
        .body = body.control,
        .stores = body.stores,
        .contracts = if (published.contracts) |rows| zx.columns.columns(ir.ContractTable, rows.*) else .{},
        .exports = frame.exports,
        .constant_exports = frame.constants,
        .type_only = output.type_only,
    };
}

pub fn initializeAnalysisTypes(handle: *anyopaque, borrowed: bool) std.mem.Allocator.Error!void {
    const analyzer = Frame.borrow(handle).analyzer;
    const allocator = analyzer.allocator;
    const table = @import("../../type_table.zig");

    // The resolved project's type names outlive this program.
    analyzer.types.* = try if (borrowed) table.columns(allocator, analyzer.base_types) else table.storage(allocator, analyzer.base_types);

    try analyzer.origins.copyValidated(analyzer.types.view(), analyzer.base_origins);
}

pub fn appendAnalysisTypes(handle: *anyopaque) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);
    const analyzer = frame.analyzer;
    const output = frame.output;
    const storage = @import("../../semantic/merging/commit.zig");

    if (analyzer.body_scratch == null) {
        try storage.append(analyzer.allocator, analyzer.types, &analyzer.origins.items, output.type_delta.*, output.nominal_delta.*);
    } else {
        try storage.retainSuffix(analyzer.allocator, analyzer.types, &analyzer.origins.items, &analyzer.base_types.labels, output.type_delta.*, output.nominal_delta.*);
    }
}

pub fn publishAnalysisExports(handle: *anyopaque) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);
    const output = frame.output;

    frame.exports = try interface.types(frame.analyzer.allocator, output.export_names, output.export_types);
}

pub fn publishAnalysisConstants(handle: *anyopaque) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);
    const output = frame.output;

    frame.constants = try interface.constants(frame.analyzer.allocator, output.constant_scope, output.constant_first);
}
