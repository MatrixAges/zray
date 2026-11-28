const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Context = @import("context.zig");
const publication = @import("../../publication/host.zig");
const model = @import("model.zig");
const interface = @import("../../publication/interface.zig");
const entry = @import("generated_analysis_publish_module");
const StoreState = std.meta.Child(@FieldType(entry.zx_pending, "store_0"));

const Publication = struct {
    analyzer: *Context,
    output: *const model.Output,
    store_0: *StoreState,
    exports: []const ir.Export = &.{},
    constants: []const ir.Constant = &.{},
    pub fn commit(self: *Publication, pending: anytype) std.mem.Allocator.Error!void {
        const next = pending.store_0 orelse return;
        const analyzer = self.analyzer;
        const output = self.output;

        switch (next.action.?) {
            .InitializeOwned => try self.initializeTypes(false),
            .InitializeBorrowed => try self.initializeTypes(true),
            .AppendTypes => try self.appendTypes(),
            .Exports => self.exports = try interface.types(analyzer.allocator, output.export_names, output.export_types),
            .Constants => self.constants = try interface.constants(analyzer.allocator, output.constant_scope, output.constant_first),
        }

        self.store_0.* = next;
    }
    fn initializeTypes(self: *Publication, borrowed: bool) std.mem.Allocator.Error!void {
        const analyzer = self.analyzer;
        const allocator = analyzer.allocator;
        const table = @import("../../type_table.zig");

        // The resolved project's type names outlive this program.
        analyzer.types.* = try if (borrowed) table.columns(allocator, analyzer.base_types) else table.storage(allocator, analyzer.base_types);

        try analyzer.origins.copyValidated(analyzer.types.view(), analyzer.base_origins);
    }
    fn appendTypes(self: *Publication) std.mem.Allocator.Error!void {
        const analyzer = self.analyzer;
        const output = self.output;
        const storage = @import("../../semantic/merging/commit.zig");

        if (analyzer.body_scratch == null) {
            try storage.append(analyzer.allocator, analyzer.types, &analyzer.origins.items, output.type_delta.*, output.nominal_delta.*);
        } else {
            try storage.retainSuffix(analyzer.allocator, analyzer.types, &analyzer.origins.items, &analyzer.base_types.labels, output.type_delta.*, output.nominal_delta.*);
        }
    }
};

pub fn apply(analyzer: *Context, mode: @FieldType(model.Context, "mode"), output: *const model.Output, file_name: []const u8) zx.Error!ir.Program {
    const Input = std.meta.Child(entry.Input);
    var state: std.meta.Child(StoreState) = .{ .action = null };
    var state_ptr: StoreState = &state;
    var host: Publication = .{ .analyzer = analyzer, .output = output, .store_0 = &state_ptr };

    const input: Input = .{
        .analysis = zx.columns.pointer(@FieldType(Input, "analysis"), output),
        .mode = @fromBackingInt(@backingInt(mode)),
        .file_name = file_name,
        .borrow_body = analyzer.body_scratch != null,
    };

    const published = entry.executeIn(analyzer.allocator, &input, &host) catch |err| switch (@as(anyerror, err)) {
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
        .exports = host.exports,
        .constant_exports = host.constants,
        .type_only = output.type_only,
    };
}
