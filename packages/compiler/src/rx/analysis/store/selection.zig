const std = @import("std");
const zx = @import("zx");
const frontend = @import("frontend");
const Store = @import("../store.zig");
const Initializer = frontend.project.SourceStoreInitializer.Borrowed;
const generated = @import("rx_options").generated_graph;
const rule = if (generated) @import("generated_rx_store_initializer_selection") else void;
pub const Error = std.mem.Allocator.Error || error{InvalidAnalysis};

pub fn collect(allocator: std.mem.Allocator, definitions: []const Store.Definition, program: *const zx.ir.Program, exported: []const frontend.project.FunctionImport) Error![]const Initializer {
    if (definitions.len == 0) return &.{};
    if (program.stores.count() == 0 and exported.len == 0) return &.{};

    var scratch = std.heap.ArenaAllocator.init(allocator);
    var buffer: [std.heap.page_size_min / 16]u8 = undefined;
    var local = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const temp = local.allocator();
    const members = try temp.alloc(u32, exported.len);
    var length: usize = 0;

    for (exported) |member| {
        if (member.intrinsic != null) continue;

        members[length] = if (member.id) |id| @backingInt(id) else std.math.maxInt(u32);
        length += 1;
    }

    if (comptime generated) return select(allocator, temp, definitions, program, members[0..length]);

    var initializers: std.ArrayList(Initializer) = .empty;

    errdefer initializers.deinit(allocator);

    try seed(allocator, definitions, program, members[0..length], &initializers);

    return initializers.items;
}

fn select(allocator: std.mem.Allocator, scratch: std.mem.Allocator, definitions: []const Store.Definition, program: *const zx.ir.Program, ids: []const u32) Error![]const Initializer {
    const Input = std.meta.Child(rule.Input);
    const Members = std.meta.Child(@FieldType(Input, "members"));
    const memory = zx.memory;
    const identities = memory.borrowListPath([]const u8, &.{"objects"}, &.{"identity"}, definitions);

    const input: Input = .{
        .entry = program.stores.paths,
        .members = &.{ .ids = ids, .stores = zx.columns.slice(@FieldType(Members, "stores"), program.functions.stores) },
        .identities = @ptrCast(&identities),
        .count = definitions.len,
    };

    const result = rule.executeValue(scratch, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    if (!result.valid) return error.InvalidAnalysis;

    const initializers = try allocator.alloc(Initializer, result.items.len);

    for (result.items, initializers) |item, *slot| {
        const definition = &definitions[@intCast(item.definition)];

        slot.* = borrow(definition, &definition.objects[@intCast(item.object)]);
    }

    return initializers;
}

fn borrow(definition: *const Store.Definition, object: *const Store.Object) Initializer {
    return .{ .identity = object.identity, .schema_version = definition.version, .program = &object.initial };
}

fn seed(allocator: std.mem.Allocator, definitions: []const Store.Definition, program: *const zx.ir.Program, ids: []const u32, output: *std.ArrayList(Initializer)) Error!void {
    for (definitions) |*definition| for (definition.objects) |*object| {
        if (try seedNeeded(program, ids, object.identity)) try output.append(allocator, borrow(definition, object));
    };
}

fn seedNeeded(program: *const zx.ir.Program, ids: []const u32, identity: []const u8) error{InvalidAnalysis}!bool {
    for (program.stores.paths) |path| if (std.mem.eql(u8, path, identity)) return true;

    for (ids) |id| {
        if (id >= program.functions.count()) return error.InvalidAnalysis;
        for (program.functions.stores[id].paths) |path| if (std.mem.eql(u8, path, identity)) return true;
    }

    return false;
}
