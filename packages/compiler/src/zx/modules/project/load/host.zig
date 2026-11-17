const std = @import("std");
const zx = @import("zx");
const Index = @import("../../source_index.zig").Map;
const interface = @import("../../interface.zig");
const Interface = @import("../interface/host.zig");
const Target = @import("../target/host.zig");
const enabled = @import("parser_options").generated_parser;
pub const State = enum(u8) { Fresh, Visiting, Done };
pub const Phase = enum { body, signature };
const Admission = if (enabled) Result(@import("generated_project_load_admission")) else enum { Push, Skip, Cycle, Depth };
const SourceAction = if (enabled) @FieldType(Result(@import("generated_project_load_source")), "action") else enum { Descend, Bind, DeferSignature, SkipSignature, RejectRx, Missing, Cycle, Depth };

fn Result(comptime module: type) type {
    return @typeInfo(@TypeOf(module.executeValue(undefined, undefined))).error_union.payload;
}

const Route = union(enum) { target: Target.Route, interface: Interface.Route };

pub fn route(internal: []const interface.Native, scoped: []const interface.Native, externals: []const interface.External, item: anytype) Route {
    if (comptime enabled) {
        const rule = @import("generated_project_load_route");
        const standard = zx.memory.borrowTextColumn("specifier", @as([]const interface.Native, &interface.standard));
        const local = zx.memory.borrowTextColumn("specifier", scoped);
        const legacy = zx.memory.borrowTextColumn("specifier", externals);
        const names = zx.memory.borrowTextColumn("module", internal);
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        const input: std.meta.Child(rule.Input) = .{
            .path = item.path,
            .intrinsic = @import("../../intrinsic.zig").specifier,
            .internal = &.{ .items = @ptrCast(&names), .length = names.count },
            .interfaces = &.{
                .native = &.{
                    .standard = &.{ .items = @ptrCast(&standard), .length = standard.count },
                    .scoped = &.{ .items = @ptrCast(&local), .length = local.count },
                    .name = item.path,
                    .check_duplicates = true,
                },
                .external = &.{ .items = @ptrCast(&legacy), .length = legacy.count },
                .function_import = item.kind == .function,
                .binding_count = item.nameCount(),
            },
        };

        const result = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;

        if (result.internal) |row| return .{ .interface = .{ .native = &internal[@intCast(row)] } };
        if (result.interface) |choice| return .{ .interface = Interface.selected(scoped, choice) };

        return .{ .target = result.route };
    }

    const kind = Target.classify(item.path);
    const row = if (kind == .Package) @import("../target/registry.zig").select(internal, "module", item.path, false).first else null;

    if (row) |index| return .{ .interface = .{ .native = &internal[index] } };
    if (kind == .Interface) return .{ .interface = Interface.routeSeed(scoped, externals, item) };

    return .{ .target = kind };
}

pub fn states(allocator: std.mem.Allocator, count: usize) std.mem.Allocator.Error![]State {
    const result = try allocator.alloc(State, count);

    @memset(result, .Fresh);

    return result;
}

pub fn admit(state_column: []State, row: usize, depth: usize) Admission {
    if (comptime enabled) {
        const generated = @import("generated_project_load_admission");
        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const marks = std.mem.sliceAsBytes(state_column);

        const input: std.meta.Child(generated.Input) = .{
            .states = marks,
            .marks = @ptrCast(&marks),
            .row = row,
            .depth = depth,
        };

        return zx.columns.invoke(generated.executeValue, empty.allocator(), &input) catch unreachable;
    }

    return switch (state_column[row]) {
        .Done => .Skip,
        .Visiting => .Cycle,
        .Fresh => accepted: {
            if (depth >= 256) break :accepted .Depth;

            state_column[row] = .Visiting;

            break :accepted .Push;
        },
    };
}

pub fn complete(state_column: []State, row: usize, depth: usize) ?usize {
    if (comptime enabled) {
        const generated = @import("generated_project_load_completion");
        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const marks = std.mem.sliceAsBytes(state_column);

        const input: std.meta.Child(generated.Input) = .{
            .marks = @ptrCast(&marks),
            .row = row,
            .depth = depth,
        };

        const completed = zx.columns.invoke(generated.executeValue, empty.allocator(), &input) catch unreachable;

        return if (completed) |child| @intCast(child) else null;
    }

    state_column[row] = .Done;

    return if (depth > 1) row else null;
}

pub const Source = struct {
    path: []const u8,
    phase: Phase,
    function_import: bool,
    exported: bool,
    depth: usize,
    row: ?usize,
    import_row: usize,
    cursor: *u64,
};

const Plan = struct {
    action: SourceAction,
    index: ?usize = null,
};

pub fn source(index: *const Index, state_column: []State, request: Source) Plan {
    if (comptime enabled) {
        const generated = @import("generated_project_load_source");
        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const Input = std.meta.Child(generated.Input);
        const marks = std.mem.sliceAsBytes(state_column);
        const cursor: []u64 = @as(*[1]u64, @ptrCast(request.cursor));

        const input: Input = .{
            .path = request.path,
            .signature = request.phase == .signature,
            .function_import = request.function_import,
            .exported = request.exported,
            .depth = request.depth,
            .row = if (request.row) |row| row else null,
            .import_row = request.import_row,
            .cursor = @ptrCast(&cursor),
            .keys = index.keys,
            .buckets = @ptrCast(&index.buckets),
            .capacity = index.buckets.len,
            .states = marks,
            .marks = @ptrCast(&marks),
        };

        const plan = zx.columns.invoke(generated.executeValue, empty.allocator(), &input) catch unreachable;

        return .{ .action = plan.action, .index = if (plan.index) |row| @intCast(row) else null };
    }

    if (std.mem.endsWith(u8, request.path, ".rx")) {
        if (request.phase != .signature) return .{ .action = .RejectRx };

        return .{ .action = if (request.function_import and !request.exported) .SkipSignature else .DeferSignature };
    }

    const row = request.row orelse index.get(request.path) orelse return .{ .action = .Missing };

    if (row >= state_column.len) return .{ .action = .Missing };

    return switch (admit(state_column, row, request.depth)) {
        .Push => suspended: {
            request.cursor.* = request.import_row + 1;

            break :suspended .{ .action = .Descend, .index = row };
        },
        .Skip => .{ .action = .Bind, .index = row },
        .Cycle => .{ .action = .Cycle },
        .Depth => .{ .action = .Depth },
    };
}
