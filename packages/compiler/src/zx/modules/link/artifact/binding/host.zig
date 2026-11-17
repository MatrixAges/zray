const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const memory = zx.memory;
const Nodes = @import("../../../artifact/nodes.zig");
const Builder = @import("../../build.zig");
const Edges = @import("../../dependencies/traversal/view.zig").Columns;
const admission = @import("../admission/host.zig");
const dependencies = @import("../../dependencies/host.zig");
const native = @import("../../native/host.zig");
const generated = @import("generated_artifact_module_binding");
const Binding = std.meta.Child(generated.Input);
const Body = std.meta.Child(@FieldType(Binding, "body"));
const Control = std.meta.Child(@typeInfo(@FieldType(Body, "control")).optional.child);
const Workspace = std.meta.Child(@FieldType(Control, "workspace"));
const inline_depth_slots = 2048 / @sizeOf(u32);
const Header = std.meta.Child(@typeInfo(@FieldType(Body, "body")).optional.child);
const Input = std.meta.Child(@typeInfo(@FieldType(Binding, "signatures")).optional.child);
const Providers = std.meta.Child(@FieldType(Input, "providers"));
const Signatures = std.meta.Child(@FieldType(Input, "signatures"));
const Native = std.meta.Child(@FieldType(Input, "native"));
const Modules = std.meta.Child(@typeInfo(@FieldType(Native, "shape")).optional.child);
const Linked = std.meta.Child(@typeInfo(@FieldType(Input, "linked_shape")).optional.child);
const Destination = std.meta.Child(@FieldType(Input, "destination"));
const Layout = std.meta.Child(std.meta.Child(@FieldType(Destination, "shape")));

pub fn bind(self: *Builder, index: usize, comptime entry: bool) Builder.Error!?Nodes.FunctionEntry {
    const module = &self.modules[index];
    const types: []const u32 = @ptrCast(self.type_mappings[index]);
    var mappings: admission.Mappings = .{ .functions = &.{}, .modules = &.{} };

    errdefer {
        self.temporary.free(mappings.modules);
        self.temporary.free(mappings.functions);
    }

    var admission_view: admission.View = undefined;
    var native_view: native.View = undefined;

    admission_view.init(module, types.len, &mappings);

    const has_natives = module.native_modules.count() != 0;

    if (has_natives) native_view.init(&self.allocator, &self.native_modules, module.native_modules, types, &mappings.modules);

    const linked = module.function != null or module.functions.count() != 0;
    const write_slots = if (linked) memory.bindColumnSet(Layout, true, &self.functions) else undefined;
    const writable: memory.ColumnSet = &write_slots;

    const destination: Destination = .{
        .storage = @ptrCast(&writable),
        .shape = null,
        .maximum_count = std.math.maxInt(u32),
        .resource = @ptrCast(&self.allocator),
    };

    var buffer: [inline_depth_slots]u32 = undefined;
    var scratch: memory.U32Scratch = .{ .allocator = self.temporary, .items = &buffer };

    defer scratch.deinit();

    var header: Header = undefined;
    var workspace: Workspace = undefined;
    var control: Control = undefined;

    if (module.function) |*value| {
        header = .{ .path = module.path, .file_name = value.file_name, .external = value.external != null };
        workspace = scratch.borrow(Workspace, entry);

        control = .{
            .control = zx.columns.pointer(@FieldType(Control, "control"), value.body.control),
            .root = if (value.body.root) |id| @backingInt(id) else null,
            .workspace = &workspace,
        };
    }

    const body: Body = .{
        .body = if (module.function != null) &header else null,
        .entry = entry,
        .stores = module.stores.count(),
        .slot = module.functions.count(),
        .target = @ptrCast(&mappings.functions),
        .destination = if (linked) &destination else null,
        .control = if (module.function != null) &control else null,
    };

    const request: dependencies.Inputs = .{
        .admission = &admission_view.input,
        .native = if (has_natives) &native_view.input else null,
        .body = &body,
    };

    const placement = if (module.functions.count() == 0)
        try dependencies.bind(self, index, &mappings, request)
    else
        try bindSignatures(self, index, &mappings, request, &destination);

    const value = if (module.function) |*function| function else return null;

    const nodes: Nodes = .{
        .allocator = self.allocator,
        .types = .{ .mapped = self.type_mappings[index] },
        .functions = .{ .indexed = mappings.functions },
        .native_modules = .{ .indexed = mappings.modules },
    };

    return @import("../body/host.zig").publish(&nodes, value, &self.functions, self.module_functions, index, placement);
}

fn bindSignatures(self: *Builder, index: usize, mappings: *admission.Mappings, binding: dependencies.Inputs, destination: *const Destination) Builder.Error!dependencies.Placement {
    const module = &self.modules[index];
    const signatures = binding.admission.layout.signatures;
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

    const native_slots = memory.bindColumnSet(Modules, false, &self.native_modules);
    const native_columns: memory.ColumnSet = &native_slots;
    var modules: Modules = undefined;
    const read_slots = memory.bindColumnSet(Linked, false, &self.functions);
    const readable: memory.ColumnSet = &read_slots;
    var snapshot: Linked = undefined;

    const request: Input = .{
        .signatures = signatures,
        .registry = &.{ .keys = self.plan.paths, .buckets = self.plan.buckets, .values = &.{} },
        .native = &.{
            .storage = @ptrCast(&native_columns),
            .shape = null,
            .snapshot = @ptrCast(&modules),
            .ids = @ptrCast(&mappings.modules),
        },
        .types = @ptrCast(self.type_mappings[index]),
        .edges = &edges.view(std.meta.Child(@FieldType(Input, "edges"))),
        .providers = &providers,
        .functions = @ptrCast(self.module_functions),
        .target = @ptrCast(&mappings.functions),
        .destination = destination,
        .read_columns = @ptrCast(&readable),
        .snapshot = @ptrCast(&snapshot),
        .linked_shape = null,
        .empty = &.{
            .symbols = @ptrCast(&ir.FunctionStorage.empty_symbols),
            .expressions = @ptrCast(&ir.FunctionStorage.empty_expressions),
            .contracts = @ptrCast(&ir.FunctionStorage.empty_contracts),
            .control = @ptrCast((ir.ControlBody{}).control),
            .stores = @ptrCast(&ir.FunctionStorage.empty_stores),
        },
    };

    var staged = binding;

    staged.signatures = &request;

    return dependencies.bind(self, index, mappings, staged);
}
