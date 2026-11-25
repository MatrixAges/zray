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

    const memory = local.allocator();
    const members = try memory.alloc(u32, exported.len);
    var length: usize = 0;

    for (exported) |member| {
        if (member.intrinsic != null) continue;

        members[length] = if (member.id) |id| @backingInt(id) else std.math.maxInt(u32);
        length += 1;
    }

    if (comptime generated) return select(allocator, definitions, program, members[0..length]);

    var initializers: std.ArrayList(Initializer) = .empty;

    errdefer initializers.deinit(allocator);

    try seed(allocator, definitions, program, members[0..length], &initializers);

    return initializers.items;
}

fn select(allocator: std.mem.Allocator, definitions: []const Store.Definition, program: *const zx.ir.Program, ids: []const u32) Error![]const Initializer {
    const Input = std.meta.Child(rule.Input);
    const Members = std.meta.Child(@FieldType(Input, "members"));
    const Fields = std.meta.Child(@FieldType(Input, "columns"));
    const memory = zx.memory;
    const identities = memory.borrowListPath([]const u8, &.{"objects"}, &.{"identity"}, definitions);
    const programs = memory.borrowListPath(zx.ir.Program, &.{"objects"}, &.{"initial"}, definitions);
    const versions = memory.borrowReadColumn(u32, "version", definitions);
    var output: memory.RowOutput(Initializer, Fields, .{}) = undefined;
    const batch_size = 32;
    var batch: [batch_size]u32 = undefined;
    var selected: []u32 = &batch;

    output.init();
    errdefer allocator.free(output.rows());

    const input: Input = .{
        .entry = program.stores.paths,
        .members = &.{ .ids = ids, .stores = zx.columns.slice(@FieldType(Members, "stores"), program.functions.stores) },
        .identities = @ptrCast(&identities),
        .programs = @ptrCast(&programs),
        .versions = @ptrCast(&versions),
        .selected = @ptrCast(&selected),
        .capacity = selected.len,
        .buffer = @ptrCast(&output.buffer),
        .columns = &output.view,
    };

    const result = rule.executeValue(allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    const written = result orelse return error.InvalidAnalysis;

    return output.rows()[0..@intCast(written)];
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
