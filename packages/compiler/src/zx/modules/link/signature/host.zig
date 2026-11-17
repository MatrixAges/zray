const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const memory = zx.memory;
const Builder = @import("../build.zig");
const Nodes = @import("../../artifact/nodes.zig");
const Edges = @import("../dependencies/traversal/view.zig").Columns;
const generated = @import("generated_artifact_signature");
const Input = std.meta.Child(generated.Input);
const Providers = std.meta.Child(@FieldType(Input, "providers"));
const Signatures = std.meta.Child(@FieldType(Input, "signatures"));
const Modules = std.meta.Child(@FieldType(Input, "modules"));

pub fn bind(self: *Builder, index: usize, mapping: []?ir.FunctionId, native_ids: []const ?ir.NativeModuleId, nodes: *Nodes) Builder.Error!void {
    if (mapping.len == 0) return;

    const module = &self.modules[index];
    const signatures = zx.columns.columns(Signatures, module.functions);
    const edges = Edges.borrow(module.dependencies, self.plan.sources(index));
    const files = memory.borrowNestedColumn([]const []const u8, &.{ "functions", "files" }, self.modules);
    const ids = memory.borrowListColumn(?u32, "members", "id", self.modules);
    const inputs = memory.borrowListColumn(?u32, "members", "input_type", self.modules);
    const outputs = memory.borrowListColumn(?u32, "members", "output_type", self.modules);
    const intrinsics = memory.borrowListColumn(?u8, "members", "intrinsic", self.modules);

    const providers: Providers = .{
        .paths = self.plan.paths,
        .files = @ptrCast(&files),
        .ids = @ptrCast(&ids),
        .inputs = @ptrCast(&inputs),
        .outputs = @ptrCast(&outputs),
        .intrinsics = @ptrCast(&intrinsics),
    };

    const modules = zx.columns.columns(Modules, self.native_modules.view());
    var linked = zx.columns.columns(Signatures, ir.SignatureTable.fromFunctions(self.functions.view()));

    var request: Input = .{
        .signatures = &signatures,
        .registry = &.{ .keys = self.plan.paths, .buckets = self.plan.buckets, .values = &.{} },
        .modules = &modules,
        .native_ids = @ptrCast(native_ids),
        .types = @ptrCast(self.type_mappings[index]),
        .linked = &linked,
        .edges = &edges.view(std.meta.Child(@FieldType(Input, "edges"))),
        .providers = &providers,
        .functions = @ptrCast(self.module_functions),
        .start = 0,
        .target = @ptrCast(&mapping),
    };

    while (true) {
        const result = zx.columns.invoke(generated.executeValue, self.temporary, @as(*const Input, &request)) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidModule,
        };

        switch (result.status) {
            .Reuse => return,
            .Insert => {
                const row: usize = @intCast(result.next);
                var source = module.functions.at(row);
                source.input_type = @fromBackingInt(result.input_type);
                source.output_type = @fromBackingInt(result.output_type);
                const native: ir.NativeModuleId = @fromBackingInt(result.native_id orelse return error.InvalidModule);
                const external = try nodes.externalMapped(source.external orelse return error.InvalidModule, native);

                try self.appendExternal(source, external);

                mapping[row] = @fromBackingInt(@as(u32, @intCast(result.row)));
                linked = zx.columns.columns(Signatures, ir.SignatureTable.fromFunctions(self.functions.view()));
                request.start = row + 1;
            },
            .Invalid => return error.InvalidModule,
            .Conflict => return error.ConflictingInterface,
        }
    }
}
