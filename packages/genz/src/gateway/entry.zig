const std = @import("std");
const zx = @import("zx");
const model = @import("root.zig");
const Slots = @import("slots.zig");
pub const Options = struct { services: []const model.Service, service_modules: []const []const u8, routes: []const model.Route, listen: []const u8, max_header_bytes: u32, max_body_bytes: u32 };

pub const ServiceColumns = struct {
    indices: []const u64,
    writable: []const bool,
    ends: []const u64,
    requires_io: []const bool,
    requires_process: []const bool,
    types: zx.ir.TypeTable,
    input_types: []const u32,
    output_types: []const u32,
};

pub fn render(allocator: std.mem.Allocator, options: Options) std.mem.Allocator.Error![]u8 {
    return renderGenerated(allocator, options, null);
}

pub fn renderBound(allocator: std.mem.Allocator, options: Options, bound: ServiceColumns) std.mem.Allocator.Error![]u8 {
    return renderGenerated(allocator, options, bound);
}

fn renderGenerated(allocator: std.mem.Allocator, options: Options, bound: ?ServiceColumns) std.mem.Allocator.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const workspace = arena.allocator();
    const entry = @import("generated_gateway_entry");
    const Parameter = @typeInfo(@TypeOf(entry.executeValue)).@"fn".param_types[1].?;
    const indirect = @typeInfo(Parameter) == .pointer;
    const Input = if (indirect) std.meta.Child(Parameter) else Parameter;
    const Bound = std.meta.Child(@typeInfo(@FieldType(Input, "bound")).optional.child);
    const Types = std.meta.Child(@FieldType(Bound, "types"));
    const Range = std.meta.Child(@FieldType(Bound, "slots"));
    var columns: Slots = undefined;
    var slots: Range = undefined;
    var table: Types = undefined;
    var source: Bound = undefined;

    if (bound) |value| {
        table = zx.ir.TypeTable.borrow(Types, value.types);
        columns = Slots.columns(value.indices, value.writable);
        slots = columns.bind(Range);

        source = .{
            .slots = &slots,
            .ends = value.ends,
            .requires_io = value.requires_io,
            .requires_process = value.requires_process,
            .types = &table,
            .input_types = value.input_types,
            .output_types = value.output_types,
        };
    }

    var writer: zx.memory.ByteWriter = .{ .allocator = allocator };

    defer writer.deinit();

    const input: Input = .{
        .writer = @ptrCast(&writer),
        .services = if (bound == null) try services(@FieldType(Input, "services"), workspace, options.services) else &.{},
        .bound = if (bound != null) &source else null,
        .routes = zx.columns.storage.view(@FieldType(Input, "routes"), options.routes),
        .service_modules = options.service_modules,
        .listen = options.listen,
        .max_header_bytes = options.max_header_bytes,
        .max_body_bytes = options.max_body_bytes,
    };

    const output = entry.executeValue(workspace, if (indirect) &input else input) catch |err| return failure(err);

    if (output.invalid_route) @panic("invalid Gateway method group");
    if (!output.valid) return error.OutOfMemory;

    return writer.finish();
}

fn services(comptime Target: type, allocator: std.mem.Allocator, values: []const model.Service) std.mem.Allocator.Error!Target {
    const Pointer = std.meta.Child(Target);
    const Row = std.meta.Child(Pointer);
    const Types = std.meta.Child(@FieldType(Row, "types"));
    const Range = std.meta.Child(@FieldType(Row, "slots"));
    const Storage = struct { types: Types, columns: Slots, slots: Range, row: Row };
    const entries = try allocator.alloc(Storage, values.len);
    const pointers = try allocator.alloc(Pointer, values.len);

    for (values, entries, pointers) |value, *entry, *pointer| {
        entry.types = zx.ir.TypeTable.borrow(Types, value.output.types);
        entry.columns = Slots.rows(value.slots);
        entry.slots = entry.columns.bind(Range);

        entry.row = .{
            .slots = &entry.slots,
            .requires_io = value.requires_io,
            .requires_process = value.requires_process,
            .types = &entry.types,
            .input_type = @backingInt(value.input_type),
            .output_type = @backingInt(value.output.id),
        };

        pointer.* = &entry.row;
    }

    return pointers;
}

fn failure(err: anyerror) std.mem.Allocator.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => @panic("invalid Gateway entry AST"),
    };
}
