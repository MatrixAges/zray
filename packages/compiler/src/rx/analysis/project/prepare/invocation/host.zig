const std = @import("std");
const rx = @import("rx");
const frontend = @import("frontend");
const prepare = @import("../../prepare.zig");
const Attributes = @import("../../../call/attributes.zig");
const target = @import("../../../call/target.zig");
const Store = @import("../../../store.zig");
const StoreCall = @import("../../../store/call.zig");
const availability = @import("../../../call/availability.zig");
const Libraries = @import("../../../call/library_bindings.zig");
const compiled_admission = @import("../../../call/compiled_admission.zig");
const wrapper = @import("../../../call/compiled_wrapper.zig");
const Graph = @import("../../source_graph/model.zig");
const previous = @import("../previous_input.zig");
const flow = @import("../flow/commit.zig");
const Error = prepare.Loader.Error;
const generated = @import("rx_options").generated_graph;
const memory = @import("zx").memory;
const entry = if (generated) @import("generated_rx_prepare_flow") else void;
const Input = if (generated) std.meta.Child(@FieldType(std.meta.Child(entry.Input), "invocation")) else void;
const AttributeView = if (generated) std.meta.Child(@FieldType(Input, "attributes")) else void;
const EdgeView = if (generated) std.meta.Child(@FieldType(Input, "edges")) else void;
const Reference = if (generated) std.meta.Child(std.meta.Child(@FieldType(EdgeView, "reference"))) else void;
const Abi = if (generated) @import("rx_execution_abi").layouts.@"zig:rx_project_host" else void;
const Admission = if (generated) Abi.CallAdmission else availability.Input;
const Route = if (generated) Abi.CallRoute else availability.Route;
const Callee = if (generated) Abi.CallCallee else availability.Callee;
const CompiledStatus = if (generated) Abi.CompiledCallStatus else wrapper.Status;
const CompiledView = if (generated) std.meta.Child(@FieldType(Input, "compiled")) else void;
const CompiledMembers = if (generated) std.meta.Child(@FieldType(CompiledView, "members")) else void;
const CompiledAdmission = if (generated) std.meta.Child(@FieldType(CompiledView, "admission")) else void;
const CompiledCheck = if (generated) std.meta.Child(@FieldType(CompiledView, "check")) else void;
const SignatureView = if (generated) std.meta.Child(@FieldType(Input, "signatures")) else void;
const SourceRanges = if (generated) std.meta.Child(@FieldType(SignatureView, "sources")) else void;
const MembersView = if (generated) std.meta.Child(@FieldType(SignatureView, "members")) else void;
const Member = std.meta.Elem(@FieldType(@FieldType(frontend.project.signature_project.Module, "signature"), "members"));
const MemberColumns = struct { names: memory.ListColumn, kinds: memory.ListColumn, stores: memory.ListColumn };

pub const Invocation = struct {
    loader: *prepare.Loader,
    cursors: flow.Cursors = @splat(0),
    node: rx.ast.Node = undefined,
    loop_condition: ?*const rx.ast.Attribute = null,
    attributes: Attributes = undefined,
    parsed: ?*const frontend.ExpressionInput.Result = null,
    getters: []const Store.Binding = &.{},
    setter: ?target.Setter = null,
    input: Input = undefined,
    reference: Reference = undefined,
    edges: EdgeView = undefined,
    attribute_view: AttributeView = undefined,
    names: if (generated) memory.TextColumn else void = undefined,
    admission: Admission = undefined,
    compiled: Libraries.Target = undefined,
    compiled_view: CompiledView = undefined,
    compiled_members: CompiledMembers = undefined,
    compiled_admission: CompiledAdmission = undefined,
    compiled_check: CompiledCheck = undefined,
    compiled_names: if (generated) memory.TextColumn else void = undefined,
    signature_view: SignatureView = undefined,
    sources: SourceRanges = undefined,
    type_only: if (generated) memory.ReadColumn else void = undefined,
    members: MembersView = undefined,
    member_columns: if (generated) MemberColumns else void = undefined,
    inline fn borrow(handle: *anyopaque) *Invocation {
        return @ptrCast(@alignCast(handle));
    }
    pub fn view(self: *Invocation) *const Input {
        self.reference = self.loader.references.view(Reference, .call);
        self.edges = .{ .reference = &self.reference, .first = 0 };
        self.attribute_view = .{ .names = @ptrCast(&self.names), .count = 0 };
        const signatures = self.loader.signatures;

        self.sources = .{ .zx_count = signatures.graph.sources.zx_count, .rx_end = signatures.graph.sources.rx_end };
        self.type_only = memory.borrowNestedColumn(bool, &.{ "signature", "type_only" }, signatures.modules);

        const member_path = &.{ "signature", "members" };

        self.member_columns = .{
            .names = memory.borrowListPath([]const u8, member_path, &.{"name"}, signatures.modules),
            .kinds = memory.borrowListPath(Member.Kind, member_path, &.{"kind"}, signatures.modules),
            .stores = memory.borrowListPath(bool, member_path, &.{"has_store"}, signatures.modules),
        };

        self.members = .{
            .names = @ptrCast(&self.member_columns.names),
            .kinds = @ptrCast(&self.member_columns.kinds),
            .stores = @ptrCast(&self.member_columns.stores),
            .callable = @backingInt(Member.Kind.callable),
        };

        self.signature_view = .{
            .indices = @ptrCast(signatures.indices),
            .sources = &self.sources,
            .forwards = signatures.forwards,
            .type_only = @ptrCast(&self.type_only),
            .members = &self.members,
        };

        self.compiled_view = .{ .members = &self.compiled_members, .admission = &self.compiled_admission, .check = &self.compiled_check };

        self.input = .{
            .state = @ptrCast(self),
            .attributes = &self.attribute_view,
            .edges = &self.edges,
            .admission = &self.admission,
            .compiled = &self.compiled_view,
            .signatures = &self.signature_view,
            .previous_end = 0,
            .previous_kind = null,
        };

        return &self.input;
    }

    pub fn open(self: *Invocation, source: rx.ast.Node, previous_end: u32) void {
        const loop = std.mem.eql(u8, source.name, "Loop");

        self.node = if (loop) source.children[0] else source;
        self.loop_condition = if (loop) target.borrowAttribute(source, "on") else null;
        self.parsed = null;
        self.getters = &.{};
        self.setter = null;

        if (comptime generated) {
            self.names = memory.borrowTextColumn("name", self.node.attributes);
            self.attribute_view.count = self.names.count;
            self.edges.first = self.loader.references.position;
            self.input.previous_end = previous_end;
            self.input.previous_kind = if (previous_end != 0) previous.kind(self.loader, previous_end - 1) else null;
        }
    }
};

pub fn bind(loader: *prepare.Loader, source: rx.ast.Node, previous_end: u32) Error!usize {
    const index = loader.calls.len;
    var state: Invocation = .{ .loader = loader };
    const view = if (comptime generated) state.view() else {};

    state.open(source, previous_end);

    if (comptime generated) {
        entry.executeIn(loader.allocator, &.{ .invocation = view, .body = null, .remaining = 0 }) catch |err| return prepare.loadError(err);
    } else {
        state.attributes = Attributes.seed(state.node.attributes);

        try readArgument(&state);
        if (state.attributes.setter != null) try authorizePreparedSetter(&state);

        const row = loader.references.seedRow(.call);
        const facts = admission(&state, &loader.references.edges[row]);
        const route = availability.seed(facts);

        if (route == .Compiled) try prepareLibrarySeed(&state, row);

        const name = if (route == .NamedSource) @import("../../../result_name.zig").resolveCall(state.attributes.function.?.*).name else "";
        const callee = availability.seedCallee(loader.signatures, route, facts, name);
        const accepts_previous = try publishPreparedCall(&state, row, route, callee.callee, callee.module, callee.signature, callee.member, route == .Source or route == .NamedSource);

        if (previous_end != 0 and accepts_previous) {
            try previous.seed(loader, index, previous_end - 1);
        }
    }

    return index;
}

pub inline fn beginPreparedCall(handle: *anyopaque, header: anytype, implicit_header: anytype, payload: anytype, previous_end: u32) std.mem.Allocator.Error!void {
    const state = Invocation.borrow(handle);

    try flow.apply(state.loader, &state.cursors, header, implicit_header, payload);

    if (payload.node) |bytes| {
        std.debug.assert(state.loader.calls.len == header.item);
        state.open(borrowNode(bytes).*, previous_end);
    }
}

pub fn rejectPreparedFlow(handle: *anyopaque, bytes: []const u8, at_output: bool, code: []const u8, message: []const u8) Error!void {
    const node = borrowNode(bytes);
    const location = if (at_output) target.attribute(node.*, "out").value_location else node.location;

    return Invocation.borrow(handle).loader.fail(location, code, message);
}

fn borrowNode(bytes: []const u8) *const rx.ast.Node {
    return @ptrCast(@alignCast(bytes.ptr));
}

pub fn readPreparedCall(handle: *anyopaque, argument: ?u64, function: ?u64, module: ?u64, setter: ?u64) Error!bool {
    const state = Invocation.borrow(handle);
    const nodes = state.node.attributes;
    state.attributes = .{ .argument = at(nodes, argument), .function = at(nodes, function), .module = at(nodes, module), .setter = at(nodes, setter) };

    try readArgument(state);

    return setter != null;
}

fn at(nodes: []const rx.ast.Attribute, slot: ?u64) ?*const rx.ast.Attribute {
    return if (slot) |row| &nodes[@intCast(row)] else null;
}

fn readArgument(state: *Invocation) Error!void {
    const loader = state.loader;
    const attribute = state.attributes.argument orelse return;
    const parsed = try loader.inputs.parse(attribute.*, loader.owner);

    if (parsed.diagnostic()) |issue| return loader.fail(rx.attributeLocation(attribute.*, issue.span.start) orelse attribute.value_location, @tagName(issue.code), issue.message);

    state.parsed = parsed;
    state.getters = try StoreCall.reads(loader.allocator, loader.backing, parsed, loader.stores);
}

pub fn authorizePreparedSetter(handle: *anyopaque) Error!void {
    const state = Invocation.borrow(handle);
    const loader = state.loader;
    const attribute = state.attributes.setter.?;
    var parsed = try @import("../../../attribute.zig").parseBorrowed(loader.backing, attribute.*, loader.owner);

    defer parsed.deinit();

    if (parsed.diagnostic()) |issue| return loader.fail(rx.attributeLocation(attribute.*, issue.span.start) orelse attribute.value_location, @tagName(issue.code), issue.message);

    switch (try StoreCall.setter(loader.backing, &parsed, loader.stores)) {
        .setter => |setter| state.setter = setter,
        .invalid => |issue| return loader.fail(rx.attributeLocation(attribute.*, issue.offset) orelse attribute.value_location, "capability", issue.message),
    }
}

pub fn readPreparedCallTarget(handle: *anyopaque, row: ?u64) void {
    const state = Invocation.borrow(handle);

    state.admission = admission(state, &state.loader.references.edges[@intCast(row.?)]);
}

pub fn resolvePreparedLibrary(handle: *anyopaque, row: ?u64) Error!u64 {
    const state = Invocation.borrow(handle);
    const loader = state.loader;
    const edge = &loader.references.edges[@intCast(row.?)];

    return switch (try frontend.project.compiled.resolve.library(loader.backing, loader.project.compiled_libraries, loader.project.root_dir, edge.target.compiled)) {
        .found => |index| index,
        .missing => libraryError(state, .Missing),
        .conflict => libraryError(state, .Conflict),
    };
}

pub fn findPreparedLibrary(handle: *anyopaque, index: u64) bool {
    const state = Invocation.borrow(handle);

    state.compiled.binding = state.loader.libraries.bound.get(@intCast(index)) orelse return false;

    return true;
}

pub fn linkPreparedLibrary(handle: *anyopaque, index: u64) Error!void {
    const state = Invocation.borrow(handle);
    const loader = state.loader;

    state.compiled.binding = loader.libraries.link(&loader.project, @intCast(index)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return libraryError(state, .Unlinked),
    };
}

pub fn readPreparedLibraryMembers(handle: *anyopaque, index: u64, row: ?u64) void {
    const state = Invocation.borrow(handle);
    const loader = state.loader;
    const name = loader.references.edges[@intCast(row.?)].target.compiled.name;
    const exports = loader.project.compiled_libraries[@intCast(index)].exports;
    state.compiled_names = memory.borrowTextColumn("name", exports);
    state.compiled_members = state.compiled.binding.exports.borrow(CompiledMembers, &state.compiled_names, name);
}

pub fn selectPreparedLibraryMember(handle: *anyopaque, index: u64, row: ?u64) void {
    const state = Invocation.borrow(handle);
    const exported = &state.loader.project.compiled_libraries[@intCast(index)].exports[@intCast(row.?)];

    state.compiled.export_row = exported;

    if (comptime generated) {
        const binding = state.compiled.binding;

        state.compiled_admission = compiled_admission.facts(CompiledAdmission, exported.function, &binding.functions, state.setter != null);

        state.compiled_check = .{
            .words = binding.checked,
            .function = if (exported.function) |function| @backingInt(function) else 0,
        };
    }
}

pub fn rejectPreparedLibrary(handle: *anyopaque, status: CompiledStatus) Error!void {
    return libraryError(Invocation.borrow(handle), switch (status) {
        inline else => |kind| @field(wrapper.Status, @tagName(kind)),
    });
}

fn libraryError(state: *const Invocation, status: wrapper.Status) Error {
    const issue = wrapper.rejection(status);

    return state.loader.fail(state.attributes.module.?.value_location, issue.code, issue.message);
}

pub fn validatePreparedLibrary(handle: *anyopaque, verified_prefix: bool, index: u64, word: u64, first: ?u64) Error!void {
    const state = Invocation.borrow(handle);

    try validateLibrary(state, verified_prefix);

    const words = state.compiled.binding.checked;

    words[@intCast(index)] = word;

    if (first) |value| words[0] = value;
}

fn validateLibrary(state: *const Invocation, verified_prefix: bool) Error!void {
    const loader = state.loader;
    const location = state.attributes.module.?.value_location;

    if (try state.compiled.validate(loader.libraries.scratch.child_allocator, &loader.project.context, location.offset, verified_prefix)) |issue| {
        return loader.fail(location, @tagName(issue.code), issue.message);
    }
}

fn prepareLibrarySeed(state: *Invocation, row: u64) Error!void {
    const index = try resolvePreparedLibrary(state, row);

    if (!findPreparedLibrary(state, index)) try linkPreparedLibrary(state, index);

    const loader = state.loader;
    const name = loader.references.edges[@intCast(row)].target.compiled.name;
    const exports = loader.project.compiled_libraries[@intCast(index)].exports;
    const member = state.compiled.binding.exports.find(exports, name) orelse return libraryError(state, .MissingExport);

    selectPreparedLibraryMember(state, index, member);

    const selected = state.compiled;

    if (wrapper.reject(selected.export_row.function, &selected.binding.functions, state.setter != null)) |issue| {
        return state.loader.fail(state.attributes.module.?.value_location, issue.code, issue.message);
    }

    const words = selected.binding.checked;
    const bit = @as(u64, @backingInt(selected.export_row.function.?)) + 1;
    const word = bit / @bitSizeOf(u64);
    const mask = @as(u64, 1) << @as(u6, @truncate(bit));

    if (words[word] & mask != 0) return;

    try validateLibrary(state, words[0] & 1 != 0);

    words[word] |= mask;
    words[0] |= 1;
}

fn admission(state: *const Invocation, edge: *const Graph.Edge) Admission {
    return .{
        .target = switch (edge.target) {
            .source => .Source,
            .compiled => .Compiled,
            .native => .Native,
        },
        .owner = if (edge.target == .source) edge.target.source else 0,
        .reference = if (state.attributes.function) |attribute| attribute.value else "",
        .named = edge.named,
        .declared_setter = state.attributes.setter != null,
        .setter = state.setter != null,
        .ambient_store = state.loader.project.context.stores.len != 0,
    };
}

pub fn publishPreparedCall(handle: *anyopaque, row: ?u64, route: Route, kind: Callee, module_row: ?u64, signature: ?u64, member: ?u64, local: bool) Error!bool {
    const state = Invocation.borrow(handle);
    const loader = state.loader;
    const index = loader.calls.len;
    const attributes = state.attributes;
    const selected = loader.references.take(@intCast(row.?));
    const edge = selected.edge;

    const callee: prepare.Callee = switch (route) {
        .Source, .AuthorizedSource, .NamedSource => try loadSource(state, edge.location, route == .NamedSource, kind, module_row, signature, member),
        .Compiled => .{ .signature = state.compiled.ports() },
        .NamedSetter => return loader.fail(attributes.function.?.value_location, "capability", "a named Call cannot grant a Store setter"),
        .NamedTarget => return loader.fail(attributes.function.?.value_location, "module", "a qualified Call.fn requires a ZX source module"),
        .Native => return loader.fail(edge.location, "module", "native and standard imports must use the interface registry"),
        .Denied => return loader.fail(state.node.location, "capability", "Store calls require explicit per-call authorization from module declarations"),
    };

    try loader.calls.append(loader.allocator, .{
        .node = state.node,
        .setter = state.setter,
        .getters = state.getters,
        .input = attributes.argument,
        .loop_condition = state.loop_condition,
        .name_source = attributes.function orelse attributes.module.?,
        .target_kind = switch (route) {
            inline .Source, .NamedSource, .AuthorizedSource, .Compiled => |target_kind| @field(prepare.CalleeKind, @tagName(target_kind)),
            else => unreachable,
        },
        .target = if (edge.target == .source) edge.target.source else selected.row,
        .callee = callee,
    });

    loader.local_calls = loader.local_calls and local;

    if (state.parsed) |parsed| try loader.recordArgument(index, parsed);

    return attributes.argument == null and (callee != .signature or callee.signature.input_type != previous.void_type);
}

fn loadSource(state: *const Invocation, edge: rx.ast.Location, named: bool, kind: Callee, module: ?u64, signature: ?u64, member: ?u64) Error!prepare.Callee {
    const loader = state.loader;
    const location = if (named) state.attributes.function.?.value_location else edge;

    return switch (kind) {
        .Module => .{ .module = @intCast(module.?) },
        .Function => .{ .signature = loader.signatures.modules[@intCast(signature.?)].signature.ports },
        .NamedFunction => .{ .signature = loader.signatures.modules[@intCast(signature.?)].signature.members[@intCast(member.?)].ports },
        .MissingModule => loader.fail(location, "module", "Call.module target is not registered"),
        .InvalidNamedTarget => loader.fail(location, "module", "a qualified Call.fn requires a ZX source module"),
        .NamedStore => loader.fail(location, "capability", "a named Call cannot invoke a Store transaction"),
        .MissingNamedFunction => loader.fail(location, "module", "ZX source does not export the selected callable function"),
        .MissingSignature => loader.fail(location, "module", "source function signature is missing from the analyzed input set"),
        .MissingForward => loader.fail(location, "module", "default re-export target is missing from the RX module collection"),
        .SetterOnForward => loader.fail(location, "capability", "RX module Store authorization belongs inside the module"),
        .TypeOnly => loader.fail(location, "module", "Call.fn requires an executable ZX module with a default function"),
        .MissingStore => loader.fail(location, "capability", "a Call.setter target must declare its second parameter as { $store }"),
        .Unused => unreachable,
    };
}

pub fn preparedPreviousName(handle: *anyopaque, row: u32, task: bool) ?[]const u8 {
    return previous.name(Invocation.borrow(handle).loader, row, task);
}

pub fn publishPreparedPrevious(handle: *anyopaque, value: []const u8) std.mem.Allocator.Error!void {
    const state = Invocation.borrow(handle);
    const owned = try state.loader.allocator.dupe(u8, value);

    try previous.publish(state.loader, state.loader.calls.len - 1, owned);
}
