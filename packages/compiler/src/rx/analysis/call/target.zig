const std = @import("std");
const frontend = @import("frontend");
const dsl = @import("dsl");
const rx = @import("rx");
const zx = @import("zx");
pub const Setter = struct { name: []const u8, path: []const u8, type_id: zx.ir.TypeId };

pub const Options = struct {
    setter: ?Setter = null,
    owner: []const u8,
    call: rx.ast.Node,
    sources: []const frontend.project.Source,
    project: frontend.project.Options = .{ .entry = "" },
};

pub const Function = struct {
    id: ?zx.ir.FunctionId = null,
    program: zx.ir.Program,
    nominal_types: @FieldType(frontend.AnalysisResult, "nominal_types"),
    store_initializers: @FieldType(frontend.AnalysisResult, "store_initializers") = &.{},
};

pub const Diagnostic = struct { path: []const u8, location: rx.ast.Location, code: []const u8, message: []const u8 };
pub const Value = union(enum) { function: Function, diagnostic: Diagnostic };

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    value: Value,
    pub fn deinit(self: *Result) void {
        self.arena.deinit();

        self.* = undefined;
    }
};

pub fn load(allocator: std.mem.Allocator, options: Options) std.mem.Allocator.Error!Result {
    var arena = std.heap.ArenaAllocator.init(allocator);

    errdefer arena.deinit();

    const value = try loadIn(arena.allocator(), options);

    return .{ .arena = arena, .value = value };
}

fn loadIn(allocator: std.mem.Allocator, options: Options) std.mem.Allocator.Error!Value {
    var checked = try dsl.validate(rx.flow.Call, allocator, options.call, {});

    defer checked.deinit();

    if (checked.value == .diagnostic) {
        const issue = checked.value.diagnostic;

        return failure(allocator, .{ .path = options.owner, .location = issue.location, .code = @tagName(issue.code), .message = issue.message });
    }

    const attributes = checked.value.data.attributes;

    const admission = @import("availability.zig").check(.{
        .source = attributes.module == null,
        .check_authority = true,
        .declared_setter = attributes.setter != null,
        .setter = options.setter != null,
        .ambient_store = options.project.context.stores.len != 0,
    });

    if (!admission.authorized) return failure(allocator, .{ .path = options.owner, .location = options.call.location, .code = "capability", .message = "Store calls require explicit per-call authorization from module declarations" });

    const fields = @import("attributes.zig").scan(options.call);
    const target = fields.module orelse fields.function.?;
    var project = options.project;

    if (project.source_index == null) project.source_index = try frontend.project.source_index.buildIn(allocator, options.sources, project.root_dir);

    const candidate = if (attributes.module) |module| block: {
        const owner = try std.fs.path.resolve(allocator, &.{ options.project.root_dir, options.owner });
        const scope = frontend.project.ImportScope.init(project.package_scopes, owner);
        const registered = frontend.project.matchPackage(scope.dependencies(project.packages), module, true);

        if (registered.first == null) return failure(allocator, .{ .path = options.owner, .location = target.value_location, .code = "unsupported", .message = "local module calls require RX module linking" });

        var reporter: zx.Reporter = .{};
        const route = frontend.project.importRoute(module);

        const resolved = frontend.project.resolveScopedTarget(.{ .source = allocator, .compiled = allocator }, owner, module, route, options.project, scope, registered, &reporter, .{ .start = target.value_location.offset, .end = target.value_location.offset }) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;

            return failure(allocator, .{ .path = options.owner, .location = target.value_location, .code = "module", .message = reporter.diagnostic.?.message });
        };

        if (resolved == .compiled) return @import("compiled.zig").load(allocator, .{
            .owner = options.owner,
            .call = options.call,
            .project = options.project,
            .setter = options.setter,
            .selected = resolved.compiled,
        });

        if (!std.mem.endsWith(u8, resolved.source, ".zx")) return failure(allocator, .{ .path = options.owner, .location = target.value_location, .code = "module", .message = "source RX module calls require project inference" });
        if (options.setter != null) return failure(allocator, .{ .path = options.owner, .location = target.value_location, .code = "capability", .message = "Call.module cannot grant a setter; Store authorization belongs inside the module" });

        break :block resolved.source;
    } else rx.resolveFunctionPath(allocator, options.owner, target.value) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        return failure(allocator, .{ .path = options.owner, .location = target.value_location, .code = "module", .message = "Call.fn must reference a ZX file within the project root" });
    };

    const absolute = try std.fs.path.resolve(allocator, &.{ project.root_dir, candidate });
    const member = if (fields.function != null) frontend.project.module_path.callMember(target.value) else null;

    const selected: frontend.project.module_path.CallSource = if (member) |name|
        try frontend.project.module_path.selectQualified(allocator, absolute, name, frontend.project.source_index.Known{ .paths = project.source_index.? })

    else
        .{ .path = try frontend.project.selectSource(allocator, absolute, project), .named = false };

    const path = selected.path;

    if (selected.named and options.setter != null) return failure(allocator, .{ .path = options.owner, .location = target.value_location, .code = "capability", .message = "a named Call cannot grant a Store setter" });

    project.entry = path;

    if (options.setter) |setter| project.context.stores = try allocator.dupe(@typeInfo(@FieldType(frontend.Context, "stores")).pointer.child, &.{.{ .handle = "$store", .path = setter.name, .type_id = setter.type_id, .readable = false }});

    const entry_path = try std.fs.path.resolve(allocator, &.{ project.root_dir, path });
    var cache = frontend.project.ParseCache{ .allocator = allocator };

    defer cache.deinit();

    for (options.sources, 0..) |source, index| {
        const source_path = try std.fs.path.resolve(allocator, &.{ project.root_dir, source.path });

        defer allocator.free(source_path);

        const parsed = try cache.getModule(source.source, source_path);

        if (parsed.diagnostic() == null) {
            const metadata = parsed.metadata();

            if (options.setter != null and !metadata.has_store) {
                if (std.mem.eql(u8, source_path, entry_path)) {
                    const location = zx.source.locate(source.source, metadata.function_start);

                    return failure(allocator, .{ .path = source.path, .location = .{ .offset = metadata.function_start, .line = location.line, .column = location.column }, .code = "capability", .message = "a Call.setter target must declare its second parameter as { store }" });
                }
            }

            if (try parsed.check(allocator)) |issue| {
                const location = zx.source.locate(options.sources[index].source, issue.span.start);

                return failure(allocator, .{ .path = source.path, .location = .{ .offset = issue.span.start, .line = location.line, .column = location.column }, .code = @tagName(issue.code), .message = issue.message });
            }
        }
    }

    const analyzed = try frontend.project.analyzeWithCache(allocator, options.sources, project, &cache);

    if (analyzed.value == .diagnostic) {
        const issue = analyzed.value.diagnostic;

        if (issue.source_index) |index| {
            const source = options.sources[index];
            const location = zx.source.locate(source.source, issue.span.start);

            return failure(allocator, .{ .path = source.path, .location = .{ .offset = issue.span.start, .line = location.line, .column = location.column }, .code = @tagName(issue.code), .message = issue.message });
        }

        return failure(allocator, .{ .path = options.owner, .location = target.value_location, .code = @tagName(issue.code), .message = issue.message });
    }

    var callee = analyzed.value.ir;

    if (selected.named) {
        for (analyzed.modules) |*module| {
            if (!std.mem.eql(u8, module.path, entry_path)) continue;

            for (module.reexports.functions) |*item| {
                if (!std.mem.eql(u8, item.name, member.?)) continue;

                const id = item.id orelse break;
                const function = callee.functions.at(@backingInt(id));

                if (function.stores.count() != 0) return failure(allocator, .{ .path = options.owner, .location = target.value_location, .code = "capability", .message = "a named Call cannot invoke a Store transaction" });

                callee = try @import("compiled_wrapper.zig").build(allocator, .{
                    .file_name = path,
                    .offset = target.value_location.offset,
                    .id = id,
                    .types = callee.types,
                    .functions = callee.functions,
                    .native_modules = callee.native_modules,
                });

                return .{ .function = .{ .id = id, .program = callee, .nominal_types = analyzed.nominal_types, .store_initializers = analyzed.store_initializers } };
            }

            break;
        }

        return failure(allocator, .{ .path = options.owner, .location = target.value_location, .code = "module", .message = "ZX source does not export the selected callable function" });
    }

    if (callee.type_only) return failure(allocator, .{ .path = options.owner, .location = target.value_location, .code = "module", .message = "Call.fn requires an executable ZX module with a default function" });

    if (options.setter) |setter| {
        const paths = try allocator.dupe([]const u8, callee.stores.paths);
        paths[0] = try allocator.dupe(u8, setter.path);
        callee.stores.paths = paths;
    }

    return .{ .function = .{ .program = callee, .nominal_types = analyzed.nominal_types, .store_initializers = analyzed.store_initializers } };
}

pub fn optionalAttribute(node: rx.ast.Node, name: []const u8) ?rx.ast.Attribute {
    return if (borrowAttribute(node, name)) |item| item.* else null;
}

pub fn borrowAttribute(node: rx.ast.Node, name: []const u8) ?*const rx.ast.Attribute {
    for (node.attributes) |*item| if (std.mem.eql(u8, item.name, name)) return item;

    return null;
}

pub fn attribute(node: rx.ast.Node, name: []const u8) rx.ast.Attribute {
    return (borrowAttribute(node, name) orelse unreachable).*;
}

pub fn failure(allocator: std.mem.Allocator, issue: Diagnostic) std.mem.Allocator.Error!Value {
    return .{ .diagnostic = .{
        .path = try allocator.dupe(u8, issue.path),
        .location = issue.location,
        .code = issue.code,
        .message = try allocator.dupe(u8, issue.message),
    } };
}
