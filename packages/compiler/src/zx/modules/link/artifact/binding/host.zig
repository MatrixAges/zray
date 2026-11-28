const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Builder = @import("../../build.zig");
const Edges = @import("../../dependencies/traversal/view.zig").Columns;
const admission = @import("../admission/host.zig");
const dependencies = @import("../../dependencies/host.zig");
const native = @import("../../native/host.zig");
const function_destination = @import("../../signature/publication/destination.zig");
const Binding = dependencies.Binding;
const Body = std.meta.Child(@FieldType(Binding, "body"));
const Control = std.meta.Child(@typeInfo(@FieldType(Body, "control")).optional.child);
const Header = std.meta.Child(@typeInfo(@FieldType(Body, "body")).optional.child);
const Input = std.meta.Child(@typeInfo(@FieldType(Binding, "signatures")).optional.child);
const Providers = std.meta.Child(@FieldType(Input, "providers"));
const Modules = std.meta.Child(@FieldType(Input, "modules"));
const Linked = std.meta.Child(@FieldType(Input, "linked"));
const Destination = std.meta.Child(@FieldType(Input, "destination"));
const Request = std.meta.Child(@typeInfo(@FieldType(Binding, "source")).optional.child);
const Source = std.meta.Child(@FieldType(Request, "source"));
const Attributes = std.meta.Child(@FieldType(Source, "attributes"));
const abi = @import("abi.zig");
const NativeBinding = std.meta.Child(@typeInfo(@FieldType(abi.Binding, "native")).optional.child);
const Empty = std.meta.Child(@FieldType(abi.PublishInput, "empty"));
const empty = function_destination.empty(Empty);

pub const Window = struct {
    providers: dependencies.Providers,
    target: function_destination.View(Destination),
    scratch: *std.heap.ArenaAllocator,
    owned: *std.heap.ArenaAllocator,
    view: View,
    entry: ?abi.Retained,
    pub fn init(self: *Window, builder: *Builder, setup: std.mem.Allocator, scratch: *std.heap.ArenaAllocator, owned: *std.heap.ArenaAllocator) std.mem.Allocator.Error!void {
        _ = setup;

        self.providers.init(builder);
        self.target.init(&builder.allocator, &builder.functions);

        self.scratch = scratch;
        self.owned = owned;
        self.entry = null;
    }

    pub fn bind(self: *Window, builder: *Builder, registration: []const u64) Builder.Error!void {
        for (registration) |index| {
            self.view.borrow(builder, @intCast(index), &self.providers, &self.target.input);

            var host: Host = .{ .view = &self.view, .builder = builder };

            const bound = abi.bind.executeIn(self.scratch.allocator(), &self.view.input, &host) catch |err| switch (@as(anyerror, err)) {
                error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
                else => return error.InvalidModule,
            };

            switch (bound.status) {
                .Ready => {},
                .Invalid => return error.InvalidModule,
                .Conflict => return error.ConflictingInterface,
                .Full => return error.OutOfMemory,
            }

            if (bound.body) |body| {
                const publish_input: abi.PublishInput = .{
                    .request = try zx.columns.bridge(@FieldType(abi.PublishInput, "request"), self.scratch.allocator(), body),
                    .storage = self.target.input.storage,
                    .empty = &empty,
                };

                const published = abi.publish.executeIn(self.owned.allocator(), &publish_input) catch |err| switch (@as(anyerror, err)) {
                    error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
                    else => return error.InvalidModule,
                };

                const outcome = published orelse return error.InvalidModule;

                if (outcome.entry) |retained| self.entry = retained;
                if (outcome.linked) |id| builder.module_functions[index] = @fromBackingInt(id);
            }

            if (!self.view.body.entry) {
                if (!self.scratch.reset(.retain_capacity)) return error.OutOfMemory;
            }
        }
    }
};

const View = struct {
    input: abi.Binding,
    admission_view: admission.View,
    native_view: native.View,
    native_binding: NativeBinding,
    dependency_view: dependencies.View,
    signatures: SignatureView,
    header: Header,
    control: Control,
    body: Body,
    request: Request,
    source: Source,
    attributes: Attributes,
    fn borrow(self: *View, builder: *Builder, index: usize, providers: *const dependencies.Providers, target: *const Destination) void {
        const module = &builder.modules[index];
        const types: []const u32 = @ptrCast(builder.type_mappings[index]);
        const entry = index == builder.plan.entry;

        self.admission_view.init(module, types.len);

        const has_natives = module.native_modules.count() != 0;

        if (has_natives) {
            self.native_view.init(&builder.allocator, &builder.native_modules, module.native_modules, types, true);

            self.native_binding = .{
                .plan = zx.columns.pointer(@FieldType(NativeBinding, "plan"), self.native_view.input.plan.?),
                .publication = zx.columns.pointer(@FieldType(NativeBinding, "publication"), self.native_view.input.publication),
            };
        }

        const linked = module.function != null or module.functions.count() != 0;

        if (module.function) |*value| {
            self.header = .{ .path = module.path, .file_name = value.file_name, .external = value.external != null };

            self.control = .{
                .control = zx.columns.pointer(@FieldType(Control, "control"), value.body.control),
                .root = if (value.body.root) |id| @backingInt(id) else null,
            };

            self.attributes = .{
                .ownership = @fromBackingInt(@intCast(@backingInt(value.output_ownership))),
                .store_mode = @fromBackingInt(@intCast(@backingInt(value.store_mode))),
                .root = self.control.root,
                .allocator_argument = false,
                .io_argument = false,
                .process_argument = false,
                .expand_tuple = false,
                .fallible = false,
                .concurrent = false,
            };

            self.source = .{
                .file = value.file_name,
                .input_type = @backingInt(value.input_type),
                .output_type = @backingInt(value.output_type),
                .attributes = &self.attributes,
                .stores = zx.columns.pointer(@FieldType(Source, "stores"), &value.stores),
                .symbols = zx.columns.pointer(@FieldType(Source, "symbols"), &value.symbols),
                .expressions = zx.columns.pointer(@FieldType(Source, "expressions"), &value.expressions),
                .contracts = zx.columns.pointer(@FieldType(Source, "contracts"), &value.contracts),
                .control = zx.columns.pointer(@FieldType(Source, "control"), value.body.control),
            };

            self.request = .{
                .source = &self.source,
                .types = types,
                .max_offset = std.math.maxInt(usize),
            };
        }

        self.body = .{
            .body = if (module.function != null) &self.header else null,
            .entry = entry,
            .stores = module.stores.count(),
            .destination = if (linked) target else null,
            .control = if (module.function != null) &self.control else null,
        };

        if (module.functions.count() != 0) self.signatures.init(builder, index, self, providers);

        self.dependency_view.init(builder, index, providers);

        self.input = .{
            .admission = &self.admission_view.input,
            .native = if (has_natives) &self.native_binding else null,
            .body = &self.body,
            .signatures = if (module.functions.count() != 0) &self.signatures.input else null,
            .dependencies = &self.dependency_view.input,
            .source = if (module.function != null) &self.request else null,
        };
    }
};

const SignatureView = struct {
    input: Input,
    edge_columns: Edges,
    edges: std.meta.Child(@FieldType(Input, "edges")),
    providers: Providers,
    modules: Modules,
    linked: Linked,
    registry: std.meta.Child(@FieldType(Input, "registry")),
    fn init(self: *SignatureView, builder: *Builder, index: usize, view: *View, providers: *const dependencies.Providers) void {
        const module = &builder.modules[index];

        self.edge_columns = Edges.borrow(module.dependencies, builder.plan.sources(index));
        self.edges = self.edge_columns.view(@FieldType(SignatureView, "edges"));
        self.providers = providers.signature(Providers, builder.plan.paths);

        self.refreshModules(&builder.native_modules);
        self.refreshLinked(&builder.functions);

        self.registry = .{ .keys = builder.plan.paths, .buckets = builder.plan.buckets, .values = &.{} };

        self.input = .{
            .signatures = view.admission_view.layout.signatures,
            .registry = &self.registry,
            .modules = &self.modules,
            .linked = &self.linked,
            .types = @ptrCast(builder.type_mappings[index]),
            .edges = &self.edges,
            .providers = &self.providers,
            .functions = @ptrCast(builder.module_functions),
        };
    }
    fn refreshModules(self: *SignatureView, modules: *const ir.NativeModuleStorage) void {
        self.modules = zx.columns.columns(Modules, modules.view());
    }
    fn refreshLinked(self: *SignatureView, functions: *const ir.FunctionStorage) void {
        self.linked = zx.columns.view(Linked, functions.view());
    }
};

const Host = struct {
    view: *View,
    builder: *Builder,
    pub fn commit(self: *Host, pending: anytype) Builder.Error!void {
        inline for (@typeInfo(@TypeOf(pending)).@"struct".field_names) |name| {
            if (@field(pending, name)) |publication| {
                if (comptime @hasField(std.meta.Child(@TypeOf(publication)), "row")) {
                    try publishSignature(self.builder, publication.row.?);

                    self.view.signatures.refreshLinked(&self.builder.functions);
                    self.view.dependency_view.refreshLinked(&self.builder.functions);
                } else {
                    try self.view.native_view.publish(publication);

                    self.view.signatures.refreshModules(&self.builder.native_modules);
                }
            }
        }
    }
};

fn publishSignature(builder: *Builder, row: anytype) Builder.Error!void {
    const allocator = builder.allocator;
    const signature = row.function;
    const flags = row.flags;
    const portable = signature.external.?;
    const module: ir.NativeModuleId = @fromBackingInt(signature.ports.native_module.?);

    const external: ir.External = .{
        .input = if (portable.parameters) |names| .{ .names = names } else null,
        .module = module,
        .member = portable.members,
        .export_name = portable.export_name,
        .allocator_argument = flags.allocator_argument,
        .io_argument = flags.io_argument,
        .process_argument = flags.process_argument,
        .expand_tuple = flags.expand_tuple,
        .fallible = flags.fallible,
        .errors = portable.errors,
        .concurrent = flags.concurrent,
    };

    try builder.functions.reserve(allocator, 1);

    const file = try allocator.dupe(u8, signature.file);

    errdefer allocator.free(file);

    const owned = try @import("../../../artifact/materializing/external_host.zig").own(allocator, external, module);

    builder.functions.appendSignatureAssumeCapacity(.{
        .file_name = file,
        .input_type = @fromBackingInt(signature.ports.input),
        .output_type = @fromBackingInt(signature.ports.output),
        .output_ownership = @fromBackingInt(@intCast(@backingInt(flags.ownership))),
        .external = owned,
    });
}
