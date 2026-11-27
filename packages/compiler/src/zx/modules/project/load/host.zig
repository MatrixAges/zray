const std = @import("std");
const zx = @import("zx");
const Index = @import("../../source_index.zig").Map;
const interface = @import("../../interface.zig");
const Interface = @import("../interface/host.zig");
const Target = @import("../target/host.zig");
const Claims = @import("imports/host.zig");
const enabled = @import("parser_options").generated_parser;
pub const State = enum(u8) { Fresh, Visiting, Done };
pub const Phase = enum { body, signature };
const Admission = enum { Push, Skip, Cycle, Depth };
const SourceAction = if (enabled) @FieldType(Result(@import("generated_project_load_source")), "action") else enum { Descend, Bind, DeferSignature, SkipSignature, RejectRx, Missing, Cycle, Depth };

fn Result(comptime module: type) type {
    return @typeInfo(@TypeOf(module.executeValue(undefined, undefined))).error_union.payload;
}

pub const Route = union(enum) { target: Target.Route, interface: Interface.Route };

const ImportResult = union(enum) { selected: Route, duplicate: zx.ast.Name };

pub fn route(allocator: std.mem.Allocator, claims: *Claims, internal: []const interface.Native, scoped: []const interface.Native, externals: []const interface.External, item: anytype) std.mem.Allocator.Error!ImportResult {
    const indexed = enabled and @hasField(@TypeOf(item.header), "storage");

    if (comptime !indexed) {
        if (try claims.claim(allocator, item)) |duplicate| return .{ .duplicate = duplicate };
    }

    if (comptime enabled) {
        const rule = @import("generated_project_load_route");
        const Input = std.meta.Child(rule.Input);
        const Claim = std.meta.Child(@typeInfo(@FieldType(Input, "claim")).optional.child);
        const standard = zx.memory.borrowTextColumn("specifier", @as([]const interface.Native, &interface.standard));
        const local = zx.memory.borrowTextColumn("specifier", scoped);
        const legacy = zx.memory.borrowTextColumn("specifier", externals);
        const names = zx.memory.borrowTextColumn("module", internal);
        var buckets: []u64 = &.{};
        var claim: ?Claim = null;

        if (comptime indexed) {
            const row = item.header.storage.imports[item.index];

            if (!row.exported and row.count != 0) {
                buckets = try claims.buckets(allocator, item.header.importBindingCount());

                claim = .{
                    .source = item.header.source,
                    .names = zx.columns.slice(@FieldType(Claim, "names"), item.header.storage.import_names),
                    .first = row.first,
                    .count = row.count,
                    .buckets = @ptrCast(&buckets),
                    .capacity = buckets.len,
                };
            }
        }

        const input: Input = .{
            .target = &.{
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
            },
            .claim = if (claim) |*view| view else null,
        };

        var arena = std.heap.ArenaAllocator.init(allocator);

        defer arena.deinit();

        var buffer: [512]u8 = undefined;
        var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

        const result = zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
            else => unreachable,
        };

        if (claim) |view| {
            for (result.slots, 0..) |slot, offset| {
                buckets[@intCast(slot)] = view.first + offset + 1;
            }
        }

        if (result.duplicate) |offset| return .{ .duplicate = item.nameAt(@intCast(offset)) };

        const selected: Route = if (result.internal) |row|
            .{ .interface = .{ .native = &internal[@intCast(row)] } }

        else if (result.interface) |choice|
            .{ .interface = Interface.selected(scoped, choice) }
        else
            .{ .target = result.route };

        return .{ .selected = selected };
    }

    const kind = Target.classify(item.path);
    const row = if (kind == .Package) @import("../target/registry.zig").select(internal, "module", item.path, false).first else null;

    const selected: Route = if (row) |index|
        .{ .interface = .{ .native = &internal[index] } }

    else if (kind == .Interface)
        .{ .interface = Interface.routeSeed(scoped, externals, item) }
    else
        .{ .target = kind };

    return .{ .selected = selected };
}

pub fn states(allocator: std.mem.Allocator, count: usize) std.mem.Allocator.Error![]State {
    const result = try allocator.alloc(State, count);

    @memset(result, .Fresh);

    return result;
}

pub fn admit(state_column: []State, row: usize, depth: usize) Admission {
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

        const input: Input = .{
            .path = request.path,
            .signature = request.phase == .signature,
            .function_import = request.function_import,
            .exported = request.exported,
            .depth = request.depth,
            .row = if (request.row) |row| row else null,
            .import_row = request.import_row,
            .keys = index.keys,
            .buckets = @ptrCast(&index.buckets),
            .capacity = index.buckets.len,
            .states = std.mem.sliceAsBytes(state_column),
        };

        const plan = zx.columns.invoke(generated.executeValue, empty.allocator(), &input) catch unreachable;

        if (plan.cursor) |value| request.cursor.* = value;

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
            request.cursor.* = request.import_row;

            break :suspended .{ .action = .Descend, .index = row };
        },
        .Skip => .{ .action = .Bind, .index = row },
        .Cycle => .{ .action = .Cycle },
        .Depth => .{ .action = .Depth },
    };
}
