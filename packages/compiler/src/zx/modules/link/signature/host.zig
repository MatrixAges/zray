const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const memory = zx.memory;
const Builder = @import("../build.zig");
const Edges = @import("../dependencies/traversal/view.zig").Columns;
const generated = @import("generated_artifact_signature");
const Input = std.meta.Child(generated.Input);
const Providers = std.meta.Child(@FieldType(Input, "providers"));
const Signatures = std.meta.Child(@FieldType(Input, "signatures"));
const Modules = std.meta.Child(@FieldType(Input, "modules"));
const Linked = std.meta.Child(@FieldType(Input, "linked"));
const Destination = std.meta.Child(@FieldType(Input, "destination"));
const Layout = std.meta.Child(std.meta.Child(@FieldType(Destination, "shape")));

pub fn bind(self: *Builder, index: usize, mapping: []?ir.FunctionId, native_ids: []const ?ir.NativeModuleId) Builder.Error!void {
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
    const read_slots = memory.bindColumnSet(Linked, false, &self.functions);
    const write_slots = memory.bindColumnSet(Layout, true, &self.functions);
    const readable: memory.ColumnSet = &read_slots;
    const writable: memory.ColumnSet = &write_slots;
    var initial: Linked = undefined;
    var snapshot: Linked = undefined;
    const linked = memory.readColumnSet(@ptrCast(&readable), &initial, @as(?*const Linked, null));

    const request: Input = .{
        .signatures = &signatures,
        .registry = &.{ .keys = self.plan.paths, .buckets = self.plan.buckets, .values = &.{} },
        .modules = &modules,
        .native_ids = @ptrCast(native_ids),
        .types = @ptrCast(self.type_mappings[index]),
        .linked = linked,
        .edges = &edges.view(std.meta.Child(@FieldType(Input, "edges"))),
        .providers = &providers,
        .functions = @ptrCast(self.module_functions),
        .target = @ptrCast(&mapping),
        .destination = &.{
            .storage = @ptrCast(&writable),
            .shape = null,
            .maximum_count = std.math.maxInt(u32),
            .resource = @ptrCast(&self.allocator),
        },
        .read_columns = @ptrCast(&readable),
        .snapshot = @ptrCast(&snapshot),
        .empty = &.{
            .symbols = @ptrCast(&ir.FunctionStorage.empty_symbols),
            .expressions = @ptrCast(&ir.FunctionStorage.empty_expressions),
            .contracts = @ptrCast(&ir.FunctionStorage.empty_contracts),
            .control = @ptrCast((ir.ControlBody{}).control),
            .stores = @ptrCast(&ir.FunctionStorage.empty_stores),
        },
    };

    const status = generated.executeIn(self.temporary, &request) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    return switch (status) {
        .Reuse => {},
        .Invalid => error.InvalidModule,
        .Conflict => error.ConflictingInterface,
        .Insert => unreachable,
    };
}
