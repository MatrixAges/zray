const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Origins = @import("../../nominal_origins.zig");
const Context = @import("../../../analysis/analyze.zig").Context;
const enabled = @import("parser_options").generated_parser;

pub const State = struct {
    types: ir.TypeStorage,
    native_modules: ir.NativeModuleStorage,
    origins: Origins,
};

pub const Open = union(enum) {
    state: State,
    diagnostic: zx.Diagnostic,
};

pub fn open(allocator: std.mem.Allocator, context: *const Context) std.mem.Allocator.Error!Open {
    if (comptime enabled) {
        const generated = @import("generated_project_state_open");
        const Input = std.meta.Child(generated.Input);
        const table = ir.TypeTable.borrow(std.meta.Child(@FieldType(Input, "table")), context.types);
        const modules = zx.columns.pointer(@FieldType(Input, "modules"), &context.native_modules);
        const origins = Origins.Table.borrow(std.meta.Child(@FieldType(Input, "origins")), context.nominal_types);

        const input: Input = .{
            .table = &table,
            .modules = modules,
            .origins = &origins,
            .names = context.nominal_types.names,
            .scalar_count = std.enums.values(ir.Scalar).len,
            .maximum_count = std.math.maxInt(u32),
        };

        const opened = zx.columns.invoke(generated.executeValue, allocator, &input) catch |err| return switch (@as(anyerror, err)) {
            error.OutOfMemory, error.Overflow, error.IntegerOverflow => error.OutOfMemory,
            else => unreachable,
        };

        return switch (opened.admission) {
            .Types => failure("invalid shared type table"),
            .Native => failure("invalid shared native module table"),
            .Nominal => failure("invalid shared nominal type table"),
            .Ready => .{ .state = .{
                .types = ownedColumns(ir.TypeStorage, opened.snapshot.?.types),
                .native_modules = ownedColumns(ir.NativeModuleStorage, opened.snapshot.?.modules),
                .origins = .{ .allocator = allocator, .items = ownedColumns(Origins.Storage, opened.snapshot.?.origins) },
            } },
        };
    }

    if (context.types.count() != 0 and !@import("../../../ir/type_rules.zig").validate(context.types)) return failure("invalid shared type table");
    if (!@import("../../native_context.zig").valid(context.types, context.native_modules)) return failure("invalid shared native module table");
    if (!try @import("../../../analysis/semantic/origins.zig").valid(context.types, context.nominal_types)) return failure("invalid shared nominal type table");

    const types = try @import("../../../analysis/type_table.zig").storage(allocator, context.types);
    const native_modules = try @import("../../native_context.zig").storage(allocator, context.native_modules);
    var origins: Origins = .{ .allocator = allocator };

    try origins.copyValidated(types.view(), context.nominal_types);

    return .{ .state = .{ .types = types, .native_modules = native_modules, .origins = origins } };
}

fn ownedColumns(comptime Storage: type, snapshot: anytype) Storage {
    var storage: Storage = undefined;

    // The validated snapshot allocates every column in the project allocator.
    inline for (@typeInfo(Storage).@"struct".field_names) |name| {
        @field(storage, name) = @FieldType(Storage, name).fromOwnedSlice(@constCast(@field(snapshot, name)));
    }

    return storage;
}

fn failure(message: []const u8) Open {
    return .{ .diagnostic = .{ .code = .contract, .span = .{ .start = 0, .end = 0 }, .message = message } };
}
