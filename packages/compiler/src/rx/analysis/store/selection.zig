const std = @import("std");
const zx = @import("zx");
const frontend = @import("frontend");
const Store = @import("../store.zig");
const Initializer = frontend.project.SourceStoreInitializer;
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

    var initializers: std.ArrayList(Initializer) = .empty;

    errdefer initializers.deinit(allocator);

    if (comptime generated) {
        try select(allocator, definitions, program, members[0..length], &initializers);
    } else {
        try seed(allocator, definitions, program, members[0..length], &initializers);
    }

    return initializers.items;
}

fn select(allocator: std.mem.Allocator, definitions: []const Store.Definition, program: *const zx.ir.Program, ids: []const u32, output: *std.ArrayList(Initializer)) Error!void {
    const Input = std.meta.Child(rule.Input);
    const Members = std.meta.Child(@FieldType(Input, "members"));
    const memory = @import("zxc_standard").memory;

    const members: Members = .{
        .ids = ids,
        .stores = zx.columns.slice(@FieldType(Members, "stores"), program.functions.stores),
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    for (definitions) |*definition| {
        const objects = definition.objects;
        const identities = memory.borrowTextColumn("identity", objects);
        var first: u64 = 0;

        while (first < objects.len) {
            const input: Input = .{
                .entry = program.stores.paths,
                .members = &members,
                .identities = @ptrCast(&identities),
                .count = objects.len,
                .first = first,
            };

            const result = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;

            first = result.next;

            switch (result.choice) {
                .Unused => break,
                .Needed => try append(allocator, output, definition, &objects[@intCast(first - 1)]),
                .InvalidMember => return error.InvalidAnalysis,
            }
        }
    }
}

fn append(allocator: std.mem.Allocator, output: *std.ArrayList(Initializer), definition: *const Store.Definition, object: *const Store.Object) std.mem.Allocator.Error!void {
    try output.append(allocator, .{ .identity = object.identity, .schema_version = definition.version, .program = object.initial });
}

fn seed(allocator: std.mem.Allocator, definitions: []const Store.Definition, program: *const zx.ir.Program, ids: []const u32, output: *std.ArrayList(Initializer)) Error!void {
    for (definitions) |*definition| for (definition.objects) |*object| {
        if (try seedNeeded(program, ids, object.identity)) try append(allocator, output, definition, object);
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
