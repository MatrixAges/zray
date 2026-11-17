const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Validate = @import("../ir/validate.zig");
pub const ParseCache = @import("parse_cache.zig");
pub const SemanticCache = @import("semantic_cache.zig");
pub const artifact = @import("artifact.zig");
const HostContext = @import("../analysis/analyzer/host/context.zig");
pub const FunctionImport = @import("function_import.zig");
pub const SourceStoreInitializer = @import("source_store_initializer.zig");
const Signature = @import("source_signature.zig");
pub const public_exports = @import("public_exports.zig");
const Analysis = @import("../analysis/analyze.zig");
const NominalOrigins = @import("nominal_origins.zig");
const ModuleRecord = @import("module_record.zig");
const CachePublication = @import("semantic_cache/publication.zig");
const Input = @import("module_input.zig");
const Loading = @import("project/load/host.zig");
const Interface = @import("project/interface/host.zig");
const State = @import("project/state/host.zig");
const Target = @import("project/target/host.zig");
const target_registry = @import("project/target/registry.zig");
pub const signature_project = @import("signature_project.zig");
pub const import_binding = @import("binding.zig");
pub const import_view = @import("import_view.zig");
pub const source_index = @import("source_index.zig");
pub const module_path = @import("module_path.zig");
pub const Resource = struct { path: []const u8, source: []const u8 };
pub const Source = struct { path: []const u8, source: []const u8, templates: []const Resource = &.{}, original: ?[]const u8 = null, template_origins: []const @import("../frontend/resources/root.zig").Origin = &.{} };
pub const resources = @import("../frontend/resources/root.zig");
pub const prepareSources = @import("../frontend/resources/prepare.zig").sources;
pub const compiled = @import("compiled.zig");
pub const External = @import("interface.zig").External;
pub const standard = @import("standard_interfaces").modules;
pub const NativeInterface = @import("interface.zig").Native;
pub const package_scope = @import("package_scope.zig");
pub const Package = package_scope.Package;
pub const PackageScope = package_scope.Scope;
pub const specifier = @import("specifier.zig");

pub const Options = struct {
    source_index: ?*const source_index.Map = null,
    native_interfaces: []const NativeInterface = &.{},
    internal_modules: []const NativeInterface = &.{},
    externals: []const External = &.{},
    packages: []const Package = &.{},
    package_scopes: []const PackageScope = &.{},
    compiled_libraries: []const compiled.Library = &.{},
    entry: []const u8,
    root_dir: []const u8 = ".",
    context: Analysis.Context = .{},
    pub fn internalModule(self: *const Options, name: []const u8) ?*const NativeInterface {
        if (self.internal_modules.len == 0) return null;

        const selected = target_registry.select(self.internal_modules, "module", name, false).first orelse return null;

        return &self.internal_modules[selected];
    }

    pub fn jsonStringify(self: Options, writer: anytype) !void {
        try writer.beginObject();

        inline for (@typeInfo(Options).@"struct".field_names) |name| {
            if (comptime !std.mem.eql(u8, name, "source_index") and !std.mem.eql(u8, name, "internal_modules")) {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            }
        }

        try writer.endObject();
    }
};

const Unit = struct {
    path: []const u8,
    signature: ?@import("source_signature.zig").Result = null,
    signature_aliases: []const ir.Export = &.{},
    signature_imports: []const FunctionImport = &.{},
    signature_reexports: []const FunctionImport = &.{},
    signature_constant_imports: []const ir.Constant = &.{},
    function: ?ir.FunctionId = null,
    exports: []const ir.Export = &.{},
    constants: []const ir.Constant = &.{},
    members: []const FunctionImport = &.{},
};

const NativeUnit = struct { exports: []const ir.Export, members: []const FunctionImport };
const Imported = struct { exports: []const ir.Export, constant_exports: []const ir.Constant = &.{}, members: []const FunctionImport = &.{}, default_member: ?FunctionImport = null, signatures: []const Signature.Member = &.{} };
pub const ImportTarget = Target.Target;

const LoadFrame = struct {
    index: usize,
    parsed: ParseCache.Version,
    scope: ?Target.Scope = null,
    next_import: usize = 0,
    aliases: std.ArrayList(ir.Export) = .empty,
    imported_names: @import("project/load/imports/host.zig") = .{},
    imports: std.ArrayList(FunctionImport) = .empty,
    constant_imports: std.ArrayList(ir.Constant) = .empty,
    dependencies: std.ArrayList(ModuleRecord.Import) = .empty,
    export_aliases: std.ArrayList(ir.Export) = .empty,
    export_constants: std.ArrayList(ir.Constant) = .empty,
    export_functions: std.ArrayList(FunctionImport) = .empty,
    signature_members: std.ArrayList(Signature.Member) = .empty,
    fn packageScope(self: *LoadFrame, scopes: []const PackageScope, path: []const u8) Target.Scope {
        if (self.scope) |scope| return scope;

        const scope = Target.Scope.init(scopes, path);

        self.scope = scope;

        return scope;
    }
    fn deinitScratch(self: *LoadFrame, allocator: std.mem.Allocator) void {
        self.imported_names.deinit(allocator);
        self.signature_members.deinit(allocator);
    }
};

const Project = struct {
    arena: *std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    binding_scratch: std.heap.ArenaAllocator,
    sources: []const Source,
    parse_cache: *ParseCache,
    prefetched: ?ParseCache.Prefetched = null,
    semantic_cache: ?*SemanticCache = null,
    restored_payloads: ?*zx.Arena = null,
    load_frames: std.ArrayList(LoadFrame) = .empty,
    entry_program: ?ir.Program = null,
    cache_context: CachePublication.Context = .{},
    cache_records: std.ArrayList(usize) = .empty,
    cache_root: ?usize = null,
    units: []Unit,
    load_states: []Loading.State,
    /// Each unit path to the first unit with it.
    unit_indices: source_index.Map = .empty,
    options: Options,
    reporter: *zx.Reporter,
    types: ir.TypeStorage = .{},
    nominal_origins: NominalOrigins,
    modules: std.ArrayList(ModuleRecord) = .empty,
    functions: ir.FunctionStorage = .{},
    verified: Validate.Verified = .{},
    native_modules: ir.NativeModuleStorage = .{},
    native_units: std.StringHashMapUnmanaged(NativeUnit) = .empty,
    store_initializers: std.ArrayList(compiled.StoreInitializer) = .empty,
    compiled_units: compiled.imports.Cache = .empty,
    current_source: usize = 0,
    fn bindingAllocator(self: *Project) std.mem.Allocator {
        _ = self.binding_scratch.reset(.retain_capacity);

        return self.binding_scratch.allocator();
    }
    fn loadFrames(self: *Project, index: usize, comptime phase: Loading.Phase) zx.Error!void {
        const frames = &self.load_frames;

        switch (Loading.admit(self.load_states, index, frames.items.len)) {
            .Skip => return,
            .Cycle => return self.dependencyCycle(),
            .Depth => return self.dependencyDepth(),
            .Push => try self.pushFrame(index),
        }

        var completed: ?usize = null;

        while (frames.items.len != 0) {
            const frame = &frames.items[frames.items.len - 1];
            self.current_source = frame.index;

            const dependency = switch (frame.parsed.result.*) {
                .native => |result| try self.loadInput(frame, Input.Native{ .value = result.value.parsed }, phase, completed),
                .indexed => |*result| if (ParseCache.indexed_enabled) try self.loadInput(frame, Input.Indexed{ .value = result }, phase, completed) else unreachable,
            };

            if (dependency) |child| {
                completed = null;

                try self.pushFrame(child);
            } else {
                completed = Loading.complete(self.load_states, frame.index, frames.items.len);

                frame.deinitScratch(self.arena.child_allocator);

                _ = frames.pop();
            }
        }
    }

    fn deinitScratch(self: *Project) void {
        const allocator = self.arena.child_allocator;

        self.unit_indices.deinit(allocator);

        for (self.load_frames.items) |*frame| frame.deinitScratch(allocator);

        self.load_frames.deinit(allocator);
        self.cache_records.deinit(allocator);
        self.binding_scratch.deinit();
    }

    fn pushFrame(self: *Project, index: usize) zx.Error!void {
        const unit = &self.units[index];
        const frames = &self.load_frames;
        self.current_source = index;

        const parsed = if (self.prefetched) |batch| borrowed: {
            self.parse_cache.reused += 1;

            break :borrowed batch.at(index);
        } else try self.parse_cache.getModuleVersion(self.sources[index].source, unit.path);

        if (parsed.result.diagnostic()) |diagnostic| {
            var issue = diagnostic;

            issue.message = try self.allocator.dupe(u8, issue.message);
            issue.message_allocator = null;
            self.reporter.diagnostic = issue;

            return error.InvalidSource;
        }

        try frames.append(self.arena.child_allocator, .{ .index = index, .parsed = parsed });
    }
    fn dependencyCycle(self: *Project) zx.Error {
        return self.reporter.fail(.module, .{ .start = 0, .end = 0 }, "ZX module imports must be acyclic, including unused imports");
    }
    fn dependencyDepth(self: *Project) zx.Error {
        return self.reporter.fail(.module, .{ .start = 0, .end = 0 }, "module dependency depth exceeds 256");
    }
    fn loadInput(self: *Project, frame: *LoadFrame, input: anytype, comptime phase: Loading.Phase, completed: ?usize) zx.Error!?usize {
        const index = frame.index;
        const unit = &self.units[index];
        const header = input.header();
        const import_count = header.importCount();
        const aliases = &frame.aliases;
        const imports = &frame.imports;
        const constants = &frame.constant_imports;
        var pending = completed;
        var paths = std.heap.ArenaAllocator.init(self.arena.child_allocator);

        defer paths.deinit();

        while (frame.next_import < import_count) : (frame.next_import += 1) {
            const item = @import("import_view.zig").get(header, frame.next_import);
            const selected_aliases = if (item.exported) &frame.export_aliases else aliases;
            const selected_imports = if (item.exported) &frame.export_functions else imports;
            const selected_constants = if (item.exported) &frame.export_constants else constants;
            var path_buffer: [512]u8 = undefined;
            var path_memory = std.heap.BufferFirstAllocator.init(&path_buffer, paths.allocator());

            const resolved: Target.Resolved = if (pending) |resumed| .{ .target = .{ .source = self.units[resumed].path } } else target_block: {
                if (try frame.imported_names.claim(self.arena.child_allocator, item)) |name| {
                    return self.reporter.fail(.name, name.span, "duplicate import binding");
                }

                const route = Target.classify(item.path);

                switch (route) {
                    .Invalid => return self.reporter.fail(.module, item.span, "invalid or unknown import specifier"),
                    .Intrinsic => {
                        try import_binding.apply(self.allocator, self.bindingAllocator(), item, .{
                            .target = .native,
                            .types = self.types.view(),
                            .exports = &.{},
                            .members = &@import("intrinsic.zig").exports,
                        }, self.reporter, selected_aliases, selected_imports, selected_constants);

                        if (phase == .body) try self.rememberImport(frame, item, .intrinsic, null);

                        continue;
                    },
                    .Interface => {
                        const scope = frame.packageScope(self.options.package_scopes, unit.path);
                        const scoped = scope.nativeInterfaces(self.options.native_interfaces);
                        const externals = scope.externals(self.options.externals);

                        switch (Interface.route(scoped, externals, item)) {
                            .native => |entry| {
                                try self.importNative(entry.*, item, selected_imports, selected_aliases, selected_constants);
                                if (phase == .body) try self.rememberImport(frame, item, .native, entry.key());
                            },
                            .legacy => |first| {
                                try self.importExternal(externals, first, item, imports);
                                if (phase == .body) try self.rememberImport(frame, item, .external, null);
                            },
                            .duplicate => return self.reporter.fail(.module, item.span, "duplicate native interface module"),
                            .conflict => return self.reporter.fail(.module, item.span, "native declarations conflict with legacy external signatures"),
                            .invalid_legacy => return self.reporter.fail(.module, item.span, "external interfaces require a default function import"),
                            .missing_legacy => return self.reporter.fail(.capability, item.span, "this module has no registered pure interfaces"),
                        }

                        continue;
                    },
                    .File, .Package => {
                        if (route == .Package) {
                            if (self.options.internalModule(item.path)) |entry| {
                                try self.importNative(entry.*, item, selected_imports, selected_aliases, selected_constants);
                                if (phase == .body) try self.rememberImport(frame, item, .native, entry.key());

                                continue;
                            }
                        }

                        const scratch = path_memory.allocator();
                        const scope = frame.packageScope(self.options.package_scopes, unit.path);

                        break :target_block try Target.resolveIndexed(.{ .source = scratch, .compiled = scratch }, unit.path, item.path, route, self.options, scope, null, self.reporter, item.span);
                    },
                }
            };

            defer _ = paths.reset(.retain_capacity);
            var source_path: ?[]const u8 = null;
            const target = resolved.target;

            const imported = switch (target) {
                .source => |path| block: {
                    if (pending) |child| {
                        const loaded = &self.units[child];

                        std.debug.assert(self.load_states[child] == .Done);

                        source_path = loaded.path;

                        break :block importedSource(loaded, phase);
                    }

                    const plan = Loading.source(self.options.source_index.?, self.load_states, .{
                        .path = path,
                        .phase = phase,
                        .function_import = item.kind == .function,
                        .exported = item.exported,
                        .depth = self.load_frames.items.len,
                        .row = resolved.source_row,
                    });

                    switch (plan.action) {
                        .SkipSignature => continue,
                        .DeferSignature => {
                            const retained = try self.allocator.dupe(u8, path);

                            break :block Imported{ .exports = &.{}, .signatures = &.{.{ .name = "", .kind = .deferred, .source = retained }} };
                        },
                        .RejectRx => return self.reporter.fail(.module, item.span, "ZX package entry must be a .zx source file"),
                        .Missing => return self.reporter.fail(.module, item.span, "import target is missing from the source set"),
                        .Cycle => return self.dependencyCycle(),
                        .Depth => return self.dependencyDepth(),
                        .Descend => return plan.index,
                        .Bind => {
                            const loaded = &self.units[plan.index.?];
                            source_path = loaded.path;

                            break :block importedSource(loaded, phase);
                        },
                    }
                },
                .compiled => |value| try self.loadCompiled(value, item.span),
            };

            pending = null;
            self.current_source = index;

            if (phase == .signature) {
                try self.bindSignature(frame, item, imported);
            } else {
                try @import("binding.zig").apply(self.allocator, self.bindingAllocator(), item, .{
                    .target = if (target == .source) .source else .compiled,
                    .types = self.types.view(),
                    .exports = imported.exports,
                    .constant_exports = imported.constant_exports,
                    .members = imported.members,
                    .default_member = imported.default_member,
                }, self.reporter, selected_aliases, selected_imports, selected_constants);

                try self.rememberImport(frame, item, switch (target) {
                    .source => .{ .source = source_path.? },
                    .compiled => |value| .{ .compiled = value },
                }, null);
            }
        }

        if (phase == .signature) {
            var types = @import("../analysis/types.zig"){
                .allocator = self.allocator,
                .reporter = self.reporter,
                .declarations = &.{},
                .aliases = aliases.items,
                .shared = .{ .origins = &self.nominal_origins, .origin = .{ .source = unit.path } },
                .items = self.types,
                .native_modules = self.native_modules.view(),
            };

            self.types = .{};
            defer self.types = types.items;
            unit.signature = try input.signature(&types, constants.items);

            try self.publishSignature(frame, &unit.signature.?);

            unit.signature_aliases = aliases.items;
            unit.signature_imports = imports.items;
            unit.signature_reexports = frame.export_functions.items;
            unit.signature_constant_imports = constants.items;
        } else try self.finishInput(frame, input);

        return null;
    }
    fn importedSource(unit: *const Unit, comptime phase: Loading.Phase) Imported {
        if (phase == .signature) {
            const signature = &unit.signature.?;

            return .{ .exports = signature.exports, .constant_exports = signature.constant_exports, .signatures = signature.members };
        }

        return .{ .exports = unit.exports, .constant_exports = unit.constants, .members = unit.members };
    }
    fn rememberImport(self: *Project, frame: *LoadFrame, item: anytype, target: ModuleRecord.Target.Wire, identity: ?[]const u8) zx.Error!void {
        var dependency = try ModuleRecord.copyImport(self.allocator, item, target);

        if (identity) |name| dependency.identity = try self.allocator.dupe(u8, name);
        try frame.dependencies.append(self.allocator, dependency);
    }
    fn bindSignature(self: *Project, frame: *LoadFrame, item: anytype, imported: Imported) zx.Error!void {
        const temporary = self.bindingAllocator();
        const members: import_binding.Members = .{ .default = if (imported.default_member) |*member| member else null, .named = imported.members };

        const names: import_binding.Members.Names = if (item.kind == .type_only)
            .{}

        else if (imported.signatures.len == 0)
            members.names()
        else
            .{ .named = .{ .signatures = imported.signatures } };

        const symbols = import_binding.Symbols{ .target = .source, .types = self.types.view(), .exports = imported.exports, .constants = imported.constant_exports, .functions = names };
        const selected = try import_binding.select(temporary, self.allocator, item, &symbols, self.reporter);
        const aliases = if (item.exported) &frame.export_aliases else &frame.aliases;
        const constants = if (item.exported) &frame.export_constants else &frame.constant_imports;

        try import_binding.publishTypes(self.allocator, selected, imported.exports, imported.constant_exports, aliases, constants);

        if (item.exported) for (selected.functions.names, selected.functions.indices) |name, index| {
            const row: usize = @intCast(index);
            var member = if (imported.signatures.len == 0) self.memberSignature(members.at(row)) else imported.signatures[row];
            member.name = try self.allocator.dupe(u8, name);

            try frame.signature_members.append(self.arena.child_allocator, member);
        };
    }
    fn memberSignature(self: *const Project, member: *const FunctionImport) Signature.Member {
        if (member.intrinsic != null) return .{ .name = member.name, .kind = .intrinsic };

        return .{
            .name = member.name,
            .kind = .callable,
            .ports = .{ .input_type = member.input_type.?, .output_type = member.output_type.? },
            .has_store = self.functions.stores.items[@backingInt(member.id.?)].count() != 0,
        };
    }
    fn publishSignature(self: *Project, frame: *LoadFrame, signature: *Signature.Result) zx.Error!void {
        const own: usize = @intFromBool(!signature.type_only);
        const forwarded = frame.signature_members.items;
        const native = frame.export_functions.items;
        const members = try self.allocator.alloc(Signature.Member, own + forwarded.len + native.len);

        if (own != 0) members[0] = .{ .name = "", .kind = .callable, .ports = signature.ports, .has_store = signature.has_store };

        @memcpy(members[own..][0..forwarded.len], forwarded);

        for (native, members[own + forwarded.len ..]) |*member, *binding| binding.* = self.memberSignature(member);

        signature.exports = try public_exports.merge(ir.Export, self.allocator, signature.exports, frame.export_aliases.items);
        signature.constant_exports = try public_exports.merge(ir.Constant, self.allocator, signature.constant_exports, frame.export_constants.items);
        signature.members = members;

        if (frame.export_aliases.items.len + frame.export_constants.items.len + forwarded.len + native.len == 0) return;
        try public_exports.signatureEntry(self.allocator, self.arena.child_allocator, signature, self.reporter);
    }
    fn finishInput(self: *Project, frame: *LoadFrame, input: anytype) zx.Error!void {
        const unit = &self.units[frame.index];
        const aliases = frame.aliases;
        const imports = frame.imports;
        const dependencies = frame.dependencies;
        const source_digest = frame.parsed.digest;
        const entry = std.mem.eql(u8, unit.path, self.options.entry);
        const first_type = self.types.count();
        var restored: ?@import("semantic_cache/restore.zig").Restored = null;

        if (self.semantic_cache) |cache| {
            const digest = try self.cache_context.get(self.allocator, entry, self.options.context);

            if (SemanticCache.entry_store.find(&cache.entries, unit.path, &frame.parsed.digest, digest)) |cached| {
                if (try @import("semantic_cache/restore.zig").restore(cached, .{
                    .allocator = self.allocator,
                    .backing = self.arena.child_allocator,
                    .payloads = self.restored_payloads.?,
                    .types = &self.types,
                    .origins = &self.nominal_origins,
                    .functions = &self.functions,
                    .verified = &self.verified,
                    .native_modules = self.native_modules.view(),
                    .aliases = aliases.items,
                    .imports = imports.items,
                    .members = frame.export_functions.items,
                    .constant_imports = frame.constant_imports.items,
                    .dependencies = dependencies.items,
                    .path = unit.path,
                })) |program| {
                    restored = program;
                    cache.reused += 1;
                }
            }

            if (restored == null) cache.analyzed += 1;
        }

        var program = if (restored) |result| result.program else analyze_block: {
            var analyzer = HostContext{
                .allocator = self.allocator,
                .reporter = self.reporter,
                .mode = .project,
                .base_types = self.types.view(),
                .base_origins = self.nominal_origins.items.view(),
                .native_modules = self.native_modules.view(),
                .types = &self.types,
                .aliases = aliases.items,
                .origins = &self.nominal_origins,
                .origin = .{ .source = unit.path },
                .function_imports = imports.items,
                .constant_imports = frame.constant_imports.items,
                .functions = self.functions.view(),
                .store_bindings = if (entry) self.options.context.stores else &.{},
                .store_type_count = self.options.context.types.count(),
            };

            break :analyze_block try input.analyze(&analyzer, unit.path);
        };

        const publication = try @import("project/publication/host.zig").module(&program, .{
            .entry = entry,
            .declared = input.header().functionName() != null,
            .linked = self.functions.count(),
            .restored = if (restored) |*value| value else null,
            .check_ownership = !@TypeOf(input).completes_ownership,
            .cache = self.semantic_cache != null,
        });

        unit.function = publication.id;

        if (publication.append) try self.functions.append(self.allocator, @import("function_body.zig").value(program));

        if (publication.ownership_count) |count| {
            program.functions = self.functions.view().prefix(count);
            program.output_ownership = try @import("../ownership/check.zig").analyze(self.allocator, program, self.reporter);

            if (unit.function) |id| self.functions.ownership.items[@backingInt(id)] = switch (program.output_ownership) {
                .copy => .Copy,
                .borrowed => .Borrowed,
                .owned => .Owned,
            };
        }

        const own: ?FunctionImport = if (unit.function) |id| .{ .name = "", .id = id, .input_type = program.input_type, .output_type = program.output_type } else null;
        unit.exports = try public_exports.merge(ir.Export, self.allocator, program.exports, frame.export_aliases.items);
        unit.constants = try public_exports.merge(ir.Constant, self.allocator, program.constant_exports, frame.export_constants.items);
        unit.members = try public_exports.prepend(FunctionImport, self.allocator, own, frame.export_functions.items);

        if (frame.export_aliases.items.len + frame.export_constants.items.len + frame.export_functions.items.len != 0) {
            unit.function = try public_exports.bodyEntry(self.allocator, self.arena.child_allocator, unit.function, unit.exports, unit.constants, unit.members, self.reporter);
        }

        if (publication.publish_artifact) {
            const index = self.modules.items.len;

            try self.cache_records.append(self.arena.child_allocator, index);

            if (entry) self.cache_root = index;
        }

        try self.modules.append(self.allocator, .{
            .path = unit.path,
            .source_digest = source_digest,
            .type_range = .{ .start = first_type, .end = program.types.count() },
            .exports = program.exports,
            .constant_exports = program.constant_exports,
            .reexports = .{ .types = frame.export_aliases.items, .constants = frame.export_constants.items, .functions = frame.export_functions.items },
            .constant_imports = frame.constant_imports.items,
            .imports = dependencies.items,
            .type_imports = aliases.items,
            .function_imports = imports.items,
            .body = publication.body,
            .own_function = publication.own_function,
        });

        if (entry) {
            program.types = .{};
            program.functions = .{};
            self.entry_program = program;
        }
    }
    fn loadCompiled(self: *Project, target: compiled.Target, span: zx.Span) zx.Error!Imported {
        const exported = compiled.imports.load(self.allocator, &self.options, target, .{
            .types = &self.types,
            .origins = &self.nominal_origins,
            .functions = &self.functions,
            .native_modules = &self.native_modules,
        }, &self.compiled_units, &self.store_initializers) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;

            return self.reporter.fail(.module, span, compiled.imports.message(err));
        };

        const default: ?FunctionImport = if (exported.function) |id| binding: {
            const index = @backingInt(id);

            break :binding .{ .name = "", .id = id, .input_type = @fromBackingInt(self.functions.input_types.items[index]), .output_type = @fromBackingInt(self.functions.output_types.items[index]) };
        } else null;

        return .{ .exports = exported.types, .constant_exports = exported.constants, .members = exported.members, .default_member = default };
    }
    fn find(self: *Project, path: []const u8) ?usize {
        const index = self.options.source_index.?.get(path) orelse return null;

        return if (index < self.units.len) index else null;
    }

    /// Indexes the unit paths for `find`; reports whether they are unique.
    fn indexUnits(self: *Project) std.mem.Allocator.Error!bool {
        self.unit_indices = try source_index.Map.init(self.arena.child_allocator, self.units.len);

        if (comptime @import("parser_options").generated_parser) {
            for (self.units, self.unit_indices.keys) |*unit, *key| key.* = unit.path;

            return self.unit_indices.firstDuplicate(self.units.len) == null;
        }

        for (self.units, 0..) |unit, index| {
            if (!self.unit_indices.claim(index, unit.path)) return false;
        }

        return true;
    }
    fn nativeModule(self: *Project, source: []const u8, identity: ?[]const u8, name: []const u8, span: zx.Span) zx.Error!ir.NativeModuleId {
        const selected = target_registry.registration(self.native_modules.view(), identity orelse source, name);

        if (!selected.valid) return self.reporter.fail(.module, span, "native import names must be nonempty UTF-8 strings");

        const id = selected.id orelse return error.OutOfMemory;

        if (selected.existing) return id;
        try self.native_modules.append(self.allocator, .{ .specifier = try self.allocator.dupe(u8, source), .identity = if (identity) |key| try self.allocator.dupe(u8, key) else null, .import_name = try self.allocator.dupe(u8, name) });

        self.verified.functions = 0;
        self.verified.native = false;

        return id;
    }
    fn importNative(self: *Project, entry: NativeInterface, item: anytype, imports: *std.ArrayList(FunctionImport), aliases: *std.ArrayList(ir.Export), constants: *std.ArrayList(ir.Constant)) zx.Error!void {
        const unit = self.native_units.get(entry.key()) orelse blk: {
            const module_id = try self.nativeModule(entry.specifier, entry.identity, entry.module, item.span);

            const loaded = if (self.semantic_cache) |cache|
                try cache.native.load(self.allocator, entry, .{ .module = module_id, .types = &self.types, .origins = &self.nominal_origins, .functions = &self.functions, .backing = self.arena.child_allocator }, self.reporter, item.span)
            else
                try @import("native.zig").load(self.arena, entry, module_id, &self.types, &self.nominal_origins, &self.functions, self.reporter, item.span);

            const namespace = loaded.namespace orelse try @import("compiled/host/native.zig").strings(self.allocator, entry.namespace);
            const bindings = try ir.NativeBindings.fromValues(self.allocator, loaded.exports);
            const native_index = @backingInt(module_id);
            self.verified.functions = 0;
            self.verified.native = false;
            self.native_modules.type_namespaces.items[native_index] = namespace;
            self.native_modules.type_names.items[native_index] = bindings.names;
            self.native_modules.type_ids.items[native_index] = bindings.type_ids;

            const members = if (comptime @import("parser_options").generated_parser) published: {
                self.functions.commitTail(loaded.members.len);

                break :published loaded.members;
            } else seed: {
                const rows = try self.allocator.alloc(FunctionImport, loaded.members.len);
                const first = self.functions.count();

                try self.functions.reserve(self.allocator, rows.len);

                for (loaded.members, rows, first..) |*member, *binding, index| {
                    self.functions.appendSignatureAssumeCapacity(member.signature);

                    binding.* = .{ .name = member.name, .id = @fromBackingInt(@as(u32, @intCast(index))), .input_type = member.signature.input_type, .output_type = member.signature.output_type };
                }

                break :seed rows;
            };

            const result = NativeUnit{ .exports = loaded.exports, .members = members };
            const key = self.native_modules.view().at(native_index).key();

            try self.native_units.put(self.allocator, key, result);

            break :blk result;
        };

        try @import("binding.zig").apply(self.allocator, self.bindingAllocator(), item, .{
            .target = .native,
            .types = self.types.view(),
            .exports = unit.exports,
            .members = unit.members,
        }, self.reporter, aliases, imports, constants);
    }
    fn importExternal(self: *Project, registry: []const External, first: usize, item: anytype, imports: *std.ArrayList(FunctionImport)) zx.Error!void {
        const local = item.nameAt(0).text;
        var namespace: ?[]const u8 = null;

        if (comptime @import("parser_options").generated_parser) {
            const plan = try Interface.legacyPlan(self.bindingAllocator(), registry, first, item.path, local);

            for (plan.rows, plan.names) |row, name| {
                try self.appendExternal(registry[@intCast(row)], item.span, .{ .name = name, .namespace = plan.namespace }, &namespace, imports);
            }

            if (plan.invalid) return self.externalCollision(item.span);

            return;
        }

        var bindings: Interface.Legacy = .{};

        defer bindings.names.deinit(self.arena.child_allocator);

        for (registry[first..]) |entry| {
            if (!std.mem.eql(u8, entry.specifier, item.path)) continue;

            const binding = try bindings.bind(self.arena.child_allocator, entry.export_name, local) orelse return self.externalCollision(item.span);

            try self.appendExternal(entry, item.span, binding, &namespace, imports);
        }
    }
    fn externalCollision(self: *Project, span: zx.Span) zx.Error {
        return self.reporter.fail(.module, span, "external modules require unique members or one default function");
    }
    fn appendExternal(self: *Project, entry: External, span: zx.Span, binding: Interface.Binding, namespace: *?[]const u8, imports: *std.ArrayList(FunctionImport)) zx.Error!void {
        const shared = @import("../analysis/types.zig").Shared{ .origins = &self.nominal_origins, .origin = .{ .external = .{
            .module = entry.key(),
            .member = entry.exportName(),
        } } };

        const imported = try @import("external.zig").load(self.allocator, entry, try self.nativeModule(entry.specifier, entry.identity, entry.implementation.module, span), span, &self.types, shared, self.reporter);
        const function_id: ir.FunctionId = @fromBackingInt(@intCast(self.functions.count()));

        try self.functions.append(self.allocator, imported.function);

        if (namespace.* == null) {
            if (binding.namespace) |name| namespace.* = try self.allocator.dupe(u8, name);
        }

        try imports.append(self.allocator, .{
            .namespace = namespace.*,
            .name = try self.allocator.dupe(u8, binding.name),
            .id = function_id,
            .input_type = imported.function.input_type,
            .output_type = imported.function.output_type,
        });
    }
};

pub fn analyze(allocator: std.mem.Allocator, sources: []const Source, options: Options) std.mem.Allocator.Error!Analysis.Result {
    var cache = ParseCache{ .allocator = allocator };

    defer cache.deinit();

    return analyzeWithCache(allocator, sources, options, &cache);
}

pub fn analyzeWithCache(allocator: std.mem.Allocator, sources: []const Source, options: Options, cache: *ParseCache) std.mem.Allocator.Error!Analysis.Result {
    return analyzeWithCaches(allocator, sources, options, cache, null);
}

pub fn analyzeIncremental(allocator: std.mem.Allocator, sources: []const Source, options: Options, cache: *SemanticCache) std.mem.Allocator.Error!Analysis.Result {
    return analyzeWithCaches(allocator, sources, options, &cache.parse_cache, cache);
}

pub fn analyzeSignatures(allocator: std.mem.Allocator, sources: []const Source, entries: []const []const u8, options: Options) std.mem.Allocator.Error!signature_project.Result {
    return analyzeSignaturesWithCache(allocator, sources, entries, options, null);
}

/// A shared cache must outlive the returned signatures, since they may borrow parsed syntax.
pub fn analyzeSignaturesWithCache(allocator: std.mem.Allocator, sources: []const Source, entries: []const []const u8, options: Options, shared: ?*ParseCache) std.mem.Allocator.Error!signature_project.Result {
    return analyzeSignatureEntries(allocator, sources, .{ .paths = entries }, options, shared, null, null);
}

/// The validated index begins with the ZX sources in source order. The canonical path text
/// in the graph outlives these signatures. The lookup table is borrowed for this call.
pub fn analyzeRegisteredSignatures(allocator: std.mem.Allocator, sources: []const Source, entries: []const []const u8, options: Options, shared: *ParseCache, registered: *const source_index.Map) std.mem.Allocator.Error!signature_project.Result {
    return analyzeSignatureEntries(allocator, sources, .{ .paths = entries }, options, shared, registered, null);
}

/// The batch and registry come from the same graph scan. Their cache is unchanged until analysis finishes.
pub fn analyzePrefetchedSignatures(allocator: std.mem.Allocator, prefetched: ParseCache.Prefetched, entries: []const u64, options: Options, registered: *const source_index.Map) std.mem.Allocator.Error!signature_project.Result {
    if (comptime @hasField(source_index.Map, "keys")) {
        std.debug.assert(prefetched.paths.len == 0 or prefetched.paths.ptr == registered.keys.ptr);
    }

    return analyzeSignatureEntries(allocator, prefetched.sources, .{ .rows = entries }, options, prefetched.cache.?, registered, prefetched);
}

const SignatureEntries = union(enum) {
    paths: []const []const u8,
    rows: []const u64,
};

fn analyzeSignatureEntries(allocator: std.mem.Allocator, sources: []const Source, entries: SignatureEntries, options: Options, shared: ?*ParseCache, registered: ?*const source_index.Map, prefetched: ?ParseCache.Prefetched) std.mem.Allocator.Error!signature_project.Result {
    var arena = std.heap.ArenaAllocator.init(allocator);

    errdefer arena.deinit();

    const owned = arena.allocator();
    var local = ParseCache{ .allocator = owned };

    defer local.deinit();

    const cache = shared orelse &local;
    var reporter: zx.Reporter = .{};

    const state = switch (try State.open(owned, &options.context)) {
        .state => |state| state,
        .diagnostic => |issue| return .{ .arena = arena, .value = .{ .diagnostic = issue } },
    };

    const units = try allocator.alloc(Unit, sources.len);

    defer allocator.free(units);

    const load_states = try Loading.states(allocator, units.len);

    defer allocator.free(load_states);

    const indexed_paths = if (comptime @hasField(source_index.Map, "keys"))
        if (registered) |index| index.keys[0..sources.len] else null

    else
        null;

    const paths = if (prefetched) |batch| batch.paths else indexed_paths;

    if (paths) |canonical| {
        for (units, canonical) |*unit, path| unit.* = .{ .path = path };
    } else {
        for (units, sources) |*unit, source| unit.* = .{ .path = try std.fs.path.resolve(owned, &.{ options.root_dir, source.path }) };
    }

    var project = Project{ .binding_scratch = std.heap.ArenaAllocator.init(allocator), .arena = &arena, .allocator = owned, .sources = sources, .parse_cache = cache, .prefetched = prefetched, .units = units, .load_states = load_states, .options = options, .reporter = &reporter, .types = state.types, .native_modules = state.native_modules, .nominal_origins = state.origins };

    defer project.deinitScratch();

    if (registered == null and !try project.indexUnits()) return .{ .arena = arena, .value = .{ .diagnostic = .{ .code = .module, .span = .{ .start = 0, .end = 0 }, .message = "source paths must be unique after normalization" } } };

    project.options.source_index = registered orelse &project.unit_indices;

    const count = switch (entries) {
        inline else => |items| items.len,
    };

    const modules = try owned.alloc(signature_project.Module, count);

    for (modules, 0..) |*module, position| {
        const selected: ?usize = switch (entries) {
            .rows => |rows| if (rows[position] < units.len) @intCast(rows[position]) else null,
            .paths => |names| lookup: {
                const entry = names[position];
                const path = if (registered != null) entry else try std.fs.path.resolve(owned, &.{ options.root_dir, entry });

                break :lookup project.find(path);
            },
        };

        const index = selected orelse return .{ .arena = arena, .value = .{ .diagnostic = .{ .code = .module, .span = .{ .start = 0, .end = 0 }, .message = "signature entry module is missing" } } };

        project.loadFrames(index, .signature) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;

            var issue = reporter.diagnostic.?;
            issue.source_index = project.current_source;

            return .{ .arena = arena, .value = .{ .diagnostic = issue } };
        };

        module.* = .{
            .path = units[index].path,
            .source_row = index,
            .signature = units[index].signature.?,
            .type_imports = units[index].signature_aliases,
            .function_imports = units[index].signature_imports,
            .reexport_functions = units[index].signature_reexports,
            .constant_imports = units[index].signature_constant_imports,
        };
    }

    const libraries = try owned.alloc(signature_project.Library, project.compiled_units.count());
    var iterator = project.compiled_units.iterator();

    for (libraries) |*library| {
        const entry = iterator.next().?;

        library.* = .{ .index = entry.key_ptr.*, .unit = entry.value_ptr.* };
    }

    return .{ .arena = arena, .value = .{ .data = .{
        .types = project.types.view(),
        .nominal_types = project.nominal_origins.items.view(),
        .native_modules = project.native_modules.view(),
        .functions = project.functions.view(),
        .store_initializers = project.store_initializers.items,
        .modules = modules,
        .libraries = libraries,
    } } };
}

fn analyzeWithCaches(allocator: std.mem.Allocator, raw_sources: []const Source, options: Options, cache: *ParseCache, semantic_cache: ?*SemanticCache) std.mem.Allocator.Error!Analysis.Result {
    var arena = std.heap.ArenaAllocator.init(allocator);

    errdefer arena.deinit();

    var restored_payloads: ?zx.Arena = if (semantic_cache != null and options.compiled_libraries.len == 0) zx.Arena.init(allocator) else null;

    defer if (restored_payloads) |*payloads| payloads.deinit();

    const temporary = arena.allocator();
    var reporter: zx.Reporter = .{};

    const sources = switch (try prepareSources(temporary, raw_sources, options)) {
        .sources => |items| items,
        .diagnostic => |issue| return .{ .arena = arena, .value = .{ .diagnostic = issue } },
    };

    const state = switch (try State.open(temporary, &options.context)) {
        .state => |state| state,
        .diagnostic => |issue| return .{ .arena = arena, .value = .{ .diagnostic = issue } },
    };

    const units = try allocator.alloc(Unit, sources.len);

    defer allocator.free(units);

    const load_states = try Loading.states(allocator, units.len);

    defer allocator.free(load_states);

    for (sources, 0..) |source, index| units[index] = .{ .path = try std.fs.path.resolve(temporary, &.{ options.root_dir, source.path }) };

    var normalized = options;
    normalized.entry = try std.fs.path.resolve(temporary, &.{ options.root_dir, options.entry });
    var project = Project{ .binding_scratch = std.heap.ArenaAllocator.init(allocator), .arena = &arena, .allocator = temporary, .sources = sources, .parse_cache = cache, .semantic_cache = if (restored_payloads != null) semantic_cache else null, .restored_payloads = if (restored_payloads) |*payloads| payloads else null, .units = units, .load_states = load_states, .options = normalized, .reporter = &reporter, .types = state.types, .native_modules = state.native_modules, .nominal_origins = state.origins };

    defer project.deinitScratch();

    if (!try project.indexUnits()) return .{ .arena = arena, .value = .{ .diagnostic = .{ .code = .module, .span = .{ .start = 0, .end = 0 }, .message = "source paths must be unique after normalization" } } };

    project.options.source_index = &project.unit_indices;
    const root = project.find(normalized.entry) orelse return .{ .arena = arena, .value = .{ .diagnostic = .{ .code = .module, .span = .{ .start = 0, .end = 0 }, .message = "entry module is missing" } } };

    project.loadFrames(root, .body) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        var issue = try resources.diagnostic(temporary, sources[project.current_source], reporter.diagnostic.?);

        issue.source_index = project.current_source;

        return .{ .arena = arena, .value = .{ .diagnostic = issue } };
    };

    const unit = &project.units[root];
    var program = project.entry_program.?;
    program.types = project.types.view();
    program.exports = unit.exports;
    program.constant_exports = unit.constants;
    program.native_modules = project.native_modules.view();

    const publication = try @import("project/publication/host.zig").publishEntry(
        temporary,
        &program,
        unit.function,
        project.functions.view(),
    );

    project.verified.functions = @min(publication.visible_count, project.verified.functions);

    if (try Validate.validateProjectPrefix(allocator, program, project.verified)) |issue| return .{ .arena = arena, .value = .{ .diagnostic = issue } };

    var result = Analysis.Result{ .arena = arena, .value = .{ .ir = program }, .nominal_types = project.nominal_origins.items.view(), .modules = project.modules.items, .store_initializers = project.store_initializers.items, .entry_function = publication.recursive };

    if (project.semantic_cache) |semantic| {
        if (try CachePublication.publish(allocator, semantic, &result, project.cache_records.items, project.cache_root, &project.cache_context)) |issue| {
            return .{ .arena = arena, .value = .{ .diagnostic = issue } };
        }
    }

    result.restored_payloads = restored_payloads;
    restored_payloads = null;

    return result;
}

pub const resolvePath = Target.resolvePath;

pub fn resolveImport(allocator: std.mem.Allocator, from: []const u8, path: []const u8, options: Options, reporter: *zx.Reporter, span: zx.Span) zx.Error![]const u8 {
    return switch (try resolveTarget(allocator, from, path, options, reporter, span)) {
        .source => |source| source,
        .compiled => reporter.fail(.module, span, "compiled package imports require structured target loading"),
    };
}

pub fn resolveTarget(allocator: std.mem.Allocator, from: []const u8, path: []const u8, options: Options, reporter: *zx.Reporter, span: zx.Span) zx.Error!ImportTarget {
    const target = try resolveModuleTarget(allocator, from, path, options, reporter, span);

    if (target == .source and !std.mem.endsWith(u8, target.source, ".zx")) return reporter.fail(.module, span, "ZX package entry must be a .zx source file");

    return target;
}

pub const ModuleReference = struct { target: ImportTarget, file: bool };

pub fn resolveModuleReference(allocator: std.mem.Allocator, from: []const u8, path: []const u8, options: Options, reporter: *zx.Reporter, span: zx.Span) zx.Error!ModuleReference {
    const route = Target.classify(path);

    return .{
        .target = try Target.resolve(allocator, from, path, route, options, reporter, span),
        .file = route == .File,
    };
}

pub fn resolveModuleTarget(allocator: std.mem.Allocator, from: []const u8, path: []const u8, options: Options, reporter: *zx.Reporter, span: zx.Span) zx.Error!ImportTarget {
    return (try resolveModuleReference(allocator, from, path, options, reporter, span)).target;
}

pub const ImportScope = Target.Scope;
pub const ImportRoute = Target.Route;
pub const intrinsic_import = @import("intrinsic.zig").specifier;
pub const importRoute = Target.classify;
pub const resolveScopedTarget = Target.resolveScoped;
pub const resolveIndexedTarget = Target.resolveIndexed;
pub const SourceSelection = Target.SourceSelection;
pub const selectIndexedSource = Target.selectIndexed;
pub const matchPackage = @import("project/target/registry.zig").package;
pub const PackageMatch = @import("project/target/registry.zig").Match;

pub fn selectSource(allocator: std.mem.Allocator, candidate: []const u8, options: Options) std.mem.Allocator.Error![]const u8 {
    return Target.select(allocator, candidate, options.source_index);
}

pub fn checkFileTarget(from: []const u8, target: []const u8, options: Options, reporter: *zx.Reporter, span: zx.Span) zx.Error!void {
    return Target.checkFile(from, target, options.package_scopes, reporter, span);
}
