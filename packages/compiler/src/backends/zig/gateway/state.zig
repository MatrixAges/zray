const std = @import("std");
const zx = @import("zx");
const memory = zx.memory;
const generating = @import("genz");
const Library = @import("../../../library/root.zig").Result;
const Bundle = @import("../library.zig").Bundle;
const names = @import("../names.zig");
const InitializerView = @import("../store_initializers/view.zig");

pub const Result = struct {
    objects: []const generating.zx.state.Object = &.{},
    object_columns: ?generating.zx.state.ObjectColumns = null,
    services: []const generating.gateway.Service = &.{},
    bound: ?generating.gateway.entry.ServiceColumns = null,
};

pub const Error = @import("state_seed.zig").Error;

const Descriptor = struct { input_type: u32, output_type: u32, requires_io: bool, requires_process: bool };

pub fn create(allocator: std.mem.Allocator, library: *const Library, bundle: Bundle) Error!Result {
    if (comptime !@import("parser_options").generated_parser) return @import("state_seed.zig").create(allocator, library, bundle);
    if (library.exports.len != bundle.public_modules.len) return error.InvalidModule;

    const independent = try @import("frontend").storesOwnValues(bundle.arena.child_allocator, library.program);
    const identities = try names.create(allocator, bundle.arena.child_allocator, library.program, library.nominal_types);
    const entry = @import("generated_gateway_bindings");
    const Input = std.meta.Child(entry.Input);
    const Members = std.meta.Child(@FieldType(Input, "members"));
    const Types = std.meta.Child(@FieldType(Input, "types"));
    const Functions = std.meta.Child(@FieldType(Input, "functions"));
    const Initializers = std.meta.Child(@FieldType(Input, "initializers"));
    const Descriptors = std.meta.Child(@FieldType(Input, "descriptors"));
    var scratch = std.heap.ArenaAllocator.init(bundle.arena.child_allocator);

    defer scratch.deinit();

    const temporary = scratch.allocator();
    var descriptors: std.MultiArrayList(Descriptor) = .empty;

    try descriptors.resize(allocator, library.exports.len);

    const input_types = descriptors.items(.input_type);
    const output_types = descriptors.items(.output_type);
    const requires_io = descriptors.items(.requires_io);
    const requires_process = descriptors.items(.requires_process);
    const io_bytes = std.mem.sliceAsBytes(requires_io);
    const process_bytes = std.mem.sliceAsBytes(requires_process);
    const initializers = try InitializerView.init(temporary, bundle.store_initializers);
    const types = zx.ir.TypeTable.borrow(Types, library.program.types);
    const functions = zx.columns.borrow(Functions, &library.program.functions);
    const export_names = memory.borrowTextColumn("name", library.exports);
    const facade_names = memory.borrowTextColumn("name", bundle.public_modules);
    const facade_functions = memory.borrowOptionalU32Column("function", library.exports);
    const facade_io = memory.borrowReadColumn(?bool, "requires_io", bundle.public_modules);
    const facade_process = memory.borrowReadColumn(bool, "requires_process", bundle.public_modules);

    const members: Members = .{
        .export_names = @ptrCast(&export_names),
        .names = @ptrCast(&facade_names),
        .functions = @ptrCast(&facade_functions),
        .requires_io = @ptrCast(&facade_io),
        .requires_process = @ptrCast(&facade_process),
        .count = library.exports.len,
    };

    const input: Input = .{
        .types = &types,
        .type_names = identities.types,
        .functions = &functions,
        .members = &members,
        .initializers = &initializers.input(Initializers),
        .independent = independent,
        .descriptors = &Descriptors{
            .input_types = @ptrCast(&input_types),
            .output_types = @ptrCast(&output_types),
            .requires_io = @ptrCast(&io_bytes),
            .requires_process = @ptrCast(&process_bytes),
        },
    };

    const output = zx.columns.invoke(entry.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    switch (output.status) {
        .Valid => {},
        .InvalidModule => return error.InvalidModule,
        .UnsupportedHostReference => return error.UnsupportedHostReference,
        .ConflictingStore => return error.ConflictingStore,
        .MissingInitializer => return error.MissingInitializer,
        .InvalidInitializer => return error.InvalidInitializer,
    }

    const object_columns = if (generating.zx.state.generated)
        generating.zx.state.ObjectColumns.fromBindings(output.modules, output.writable, independent)

    else
        null;

    const objects = if (comptime generating.zx.state.generated)
        &.{}

    else
        try @import("../state/objects.zig").create(allocator, output.modules, output.writable, independent);

    return .{
        .objects = objects,
        .object_columns = object_columns,
        .bound = .{
            .indices = output.indices,
            .writable = output.access,
            .ends = output.ends,
            .requires_io = requires_io,
            .requires_process = requires_process,
            .types = library.program.types,
            .input_types = input_types,
            .output_types = output_types,
        },
    };
}
