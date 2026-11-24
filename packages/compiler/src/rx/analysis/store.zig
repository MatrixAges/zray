const std = @import("std");
const frontend = @import("frontend");
const dsl = @import("dsl");
const rx = @import("rx");
const zx = @import("zx");
const target = @import("call/target.zig");
pub const registry = @import("store/registry.zig");
pub const collectInitializers = @import("store/selection.zig").collect;
pub const Options = struct { aliases: []const zx.ir.Export = &.{}, owner: []const u8, node: rx.ast.Node, types: zx.ir.TypeTable = .{}, nominal_types: @FieldType(frontend.AnalysisResult, "nominal_types") = .{}, native_modules: zx.ir.NativeModuleTable = .{} };

pub const Binding = struct {
    name: []const u8,
    path: []const u8,
    type_id: zx.ir.TypeId,
    pub fn readSlot(self: Binding) zx.ir.StoreSlot {
        return .{ .path = self.path, .type_id = self.type_id, .writable = false };
    }
};

pub const Object = struct { name: []const u8, identity: []const u8, initial: zx.ir.Program };
pub const Definition = struct { source_path: []const u8, name: []const u8, version: u32, types: zx.ir.TypeTable, objects: []const Object };
pub const Value = union(enum) { definition: Definition, diagnostic: target.Diagnostic };

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    value: Value,
    pub fn deinit(self: *Result) void {
        self.arena.deinit();

        self.* = undefined;
    }
};

pub fn analyze(allocator: std.mem.Allocator, options: Options) std.mem.Allocator.Error!Result {
    var arena = std.heap.ArenaAllocator.init(allocator);

    errdefer arena.deinit();

    const value = try analyzeIn(arena.allocator(), allocator, options);

    return .{ .arena = arena, .value = value };
}

pub fn analyzeIn(allocator: std.mem.Allocator, backing: std.mem.Allocator, options: Options) std.mem.Allocator.Error!Value {
    return analyzeWithValues(allocator, backing, options, null);
}

pub fn analyzeWithValues(allocator: std.mem.Allocator, backing: std.mem.Allocator, options: Options, value_imports: ?frontend.expressions.BindingColumns) std.mem.Allocator.Error!Value {
    var scratch = std.heap.ArenaAllocator.init(backing);

    defer scratch.deinit();

    const temporary = scratch.allocator();
    var groups: ?rx.store.Groups = null;
    var checked = try dsl.validate(rx.store.Store, temporary, options.node, &groups);

    defer checked.deinit();

    if (checked.value == .diagnostic) {
        const issue = checked.value.diagnostic;

        return failure(allocator, options.owner, issue.location, @tagName(issue.code), issue.message);
    }

    const path = rx.normalizeStorePath(allocator, options.owner) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        return failure(allocator, options.owner, options.node.location, "module", "Store definition must have a project-relative .store.rx path");
    };

    const attributes = checked.value.data.attributes;
    const preparation = @import("store/prepare/host.zig");

    var frame: preparation.Frame = .{
        .allocator = allocator,
        .temporary = temporary,
        .backing = backing,
        .options = &options,
        .path = path,
        .name = attributes.name,
        .version = attributes.version,
        .groups = groups,
        .value_imports = value_imports,
    };

    return preparation.run(&frame);
}

pub fn failure(allocator: std.mem.Allocator, path: []const u8, location: rx.ast.Location, code: []const u8, message: []const u8) std.mem.Allocator.Error!Value {
    const failed = try target.failure(allocator, .{ .path = path, .location = location, .code = code, .message = message });

    return .{ .diagnostic = failed.diagnostic };
}
