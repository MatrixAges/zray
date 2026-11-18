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
const generated = @import("generated_artifact_dependency_binding");
const Binding = dependencies.Binding;
const Body = std.meta.Child(@FieldType(Binding, "body"));
const Control = std.meta.Child(@typeInfo(@FieldType(Body, "control")).optional.child);
const Workspace = std.meta.Child(@FieldType(Control, "workspace"));
const inline_depth_slots = 2048 / @sizeOf(u32);
const Header = std.meta.Child(@typeInfo(@FieldType(Body, "body")).optional.child);
const Input = std.meta.Child(@typeInfo(@FieldType(Binding, "signatures")).optional.child);
const Providers = std.meta.Child(@FieldType(Input, "providers"));
const Native = std.meta.Child(@FieldType(Input, "native"));
const Modules = std.meta.Child(@typeInfo(@FieldType(Native, "shape")).optional.child);
const Linked = std.meta.Child(@typeInfo(@FieldType(Input, "linked_shape")).optional.child);
const Destination = std.meta.Child(@FieldType(Input, "destination"));
const Layout = std.meta.Child(std.meta.Child(@FieldType(Destination, "shape")));
const Batch = std.meta.Child(generated.Input);
const BodyHost = @import("../body/host.zig");

pub fn bind(self: *Builder, index: usize, comptime entry: bool) Builder.Error!?Nodes.FunctionEntry {
    var providers: dependencies.Providers = undefined;
    var view: View = undefined;

    providers.init(self);
    view.init(self, index, &providers, entry);
    defer view.release(self.temporary);

    const placement = try dependencies.run(self.temporary, &view.input);
    const value = if (self.modules[index].function) |*function| function else return null;
    const nodes = view.nodes(self, index);

    return BodyHost.publish(&nodes, value, &self.functions, self.module_functions, index, placement);
}

pub fn batch(self: *Builder, scratch: *std.heap.ArenaAllocator) Builder.Error!void {
    if (self.plan.dependencies.len == 0) return;

    var frame: Frame = undefined;

    frame.builder = self;

    frame.providers.init(self);

    // The batch cursor must outlive each reset of the module scratch arena.
    var progress: [2]u64 = @splat(0);
    const cursor: []u64 = &progress;

    const input: Batch = .{
        .frame = @ptrCast(&frame),
        .binding = &frame.binding.input,
        .dependencies = self.plan.dependencies,
        .scratch = @ptrCast(scratch),
        .cursor = @ptrCast(&cursor),
    };

    const status = generated.executeIn(self.temporary, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    return switch (status) {
        .Absent => {},
        .Full => error.OutOfMemory,
        .Conflict => error.ConflictingInterface,
        else => error.InvalidModule,
    };
}

const Frame = struct {
    builder: *Builder,
    binding: View,
    providers: dependencies.Providers,
};

export fn borrowArtifactBinding(opaque_frame: *const anyopaque, row: u64) void {
    const frame: *Frame = @ptrCast(@alignCast(@constCast(opaque_frame)));

    frame.binding.init(frame.builder, @intCast(row), &frame.providers, false);
}

export fn zxcPublishArtifactBody(opaque_frame: *const anyopaque, row: u64, append: bool, reject_store: bool) u8 {
    const frame: *Frame = @ptrCast(@alignCast(@constCast(opaque_frame)));
    const index: usize = @intCast(row);
    const builder = frame.builder;
    const value = &builder.modules[index].function.?;
    const nodes = frame.binding.nodes(builder, index);

    // Preserve the existing executeState boundary for exclusive function columns.
    _ = BodyHost.publish(&nodes, value, &builder.functions, builder.module_functions, index, if (append) .Append else if (reject_store) .RejectStoreDependency else unreachable) catch |err| return switch (err) {
        error.OutOfMemory => 1,
        else => 2,
    };

    return 0;
}

const View = struct {
    input: Binding,
    mappings: admission.Mappings,
    admission_view: admission.View,
    native_view: native.View,
    dependency_view: dependencies.View,
    signatures: SignatureView,
    write_slots: [@typeInfo(Layout).@"struct".field_names.len]*anyopaque,
    writable: memory.ColumnSet,
    destination: Destination,
    buffer: [inline_depth_slots]u32,
    scratch: memory.U32Scratch,
    header: Header,
    workspace: Workspace,
    control: Control,
    body: Body,
    fn init(self: *View, builder: *Builder, index: usize, providers: *const dependencies.Providers, entry: bool) void {
        const module = &builder.modules[index];
        const types: []const u32 = @ptrCast(builder.type_mappings[index]);

        self.mappings = .{ .functions = &.{}, .modules = &.{} };

        self.admission_view.init(module, types.len, &self.mappings);

        const has_natives = module.native_modules.count() != 0;

        if (has_natives) self.native_view.init(&builder.allocator, &builder.native_modules, module.native_modules, types, &self.mappings.modules);

        const linked = module.function != null or module.functions.count() != 0;

        if (linked) self.write_slots = memory.bindColumnSet(Layout, true, &builder.functions);

        self.writable = &self.write_slots;

        self.destination = .{
            .storage = @ptrCast(&self.writable),
            .shape = null,
            .maximum_count = std.math.maxInt(u32),
            .resource = @ptrCast(&builder.allocator),
        };

        self.scratch = .{ .allocator = builder.temporary, .items = &self.buffer };

        if (module.function) |*value| {
            self.header = .{ .path = module.path, .file_name = value.file_name, .external = value.external != null };
            self.workspace = self.scratch.borrow(Workspace, entry);

            self.control = .{
                .control = zx.columns.pointer(@FieldType(Control, "control"), value.body.control),
                .root = if (value.body.root) |id| @backingInt(id) else null,
                .workspace = &self.workspace,
            };
        }

        self.body = .{
            .body = if (module.function != null) &self.header else null,
            .entry = entry,
            .stores = module.stores.count(),
            .slot = module.functions.count(),
            .target = @ptrCast(&self.mappings.functions),
            .destination = if (linked) &self.destination else null,
            .control = if (module.function != null) &self.control else null,
        };

        if (module.functions.count() != 0) self.signatures.init(builder, index, self, providers);

        self.dependency_view.init(builder, index, &self.mappings, providers);

        self.input = .{
            .admission = &self.admission_view.input,
            .native = if (has_natives) &self.native_view.input else null,
            .body = &self.body,
            .signatures = if (module.functions.count() != 0) &self.signatures.input else null,
            .dependencies = &self.dependency_view.input,
        };
    }
    fn nodes(self: *const View, builder: *const Builder, index: usize) Nodes {
        return .{
            .allocator = builder.allocator,
            .types = .{ .mapped = builder.type_mappings[index] },
            .functions = .{ .indexed = self.mappings.functions },
            .native_modules = .{ .indexed = self.mappings.modules },
        };
    }

    fn release(self: *View, workspace: std.mem.Allocator) void {
        self.scratch.deinit();
        workspace.free(self.mappings.modules);
        workspace.free(self.mappings.functions);
    }
};

const SignatureView = struct {
    input: Input,
    edge_columns: Edges,
    edges: std.meta.Child(@FieldType(Input, "edges")),
    providers: Providers,
    native_slots: [@typeInfo(Modules).@"struct".field_names.len]*anyopaque,
    native_columns: memory.ColumnSet,
    modules: Modules,
    native: Native,
    read_slots: [@typeInfo(Linked).@"struct".field_names.len]*anyopaque,
    readable: memory.ColumnSet,
    snapshot: Linked,
    registry: std.meta.Child(@FieldType(Input, "registry")),
    fn init(self: *SignatureView, builder: *Builder, index: usize, view: *View, providers: *const dependencies.Providers) void {
        const module = &builder.modules[index];

        self.edge_columns = Edges.borrow(module.dependencies, builder.plan.sources(index));
        self.edges = self.edge_columns.view(@FieldType(SignatureView, "edges"));
        self.providers = providers.signature(Providers, builder.plan.paths);
        self.native_slots = memory.bindColumnSet(Modules, false, &builder.native_modules);
        self.native_columns = &self.native_slots;

        self.native = .{
            .storage = @ptrCast(&self.native_columns),
            .shape = null,
            .snapshot = @ptrCast(&self.modules),
            .ids = @ptrCast(&view.mappings.modules),
        };

        self.read_slots = memory.bindColumnSet(Linked, false, &builder.functions);
        self.readable = &self.read_slots;
        self.registry = .{ .keys = builder.plan.paths, .buckets = builder.plan.buckets, .values = &.{} };

        self.input = .{
            .signatures = view.admission_view.layout.signatures,
            .registry = &self.registry,
            .native = &self.native,
            .types = @ptrCast(builder.type_mappings[index]),
            .edges = &self.edges,
            .providers = &self.providers,
            .functions = @ptrCast(builder.module_functions),
            .target = @ptrCast(&view.mappings.functions),
            .destination = &view.destination,
            .read_columns = @ptrCast(&self.readable),
            .snapshot = @ptrCast(&self.snapshot),
            .linked_shape = null,
            .empty = &.{
                .symbols = @ptrCast(&ir.FunctionStorage.empty_symbols),
                .expressions = @ptrCast(&ir.FunctionStorage.empty_expressions),
                .contracts = @ptrCast(&ir.FunctionStorage.empty_contracts),
                .control = @ptrCast((ir.ControlBody{}).control),
                .stores = @ptrCast(&ir.FunctionStorage.empty_stores),
            },
        };
    }
};
