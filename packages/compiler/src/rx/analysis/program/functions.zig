const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const generated = @import("rx_options").generated_graph;
const rule = if (generated) @import("generated_rx_program_check_function") else void;
pub const Reuse = if (generated) rule.Output else enum { Invalid, Checked, CheckInitializers };

pub fn shared(actual: *const ir.FunctionTable, row: usize, expected: *const ir.Program, initializers_shared: bool) Reuse {
    if (comptime !generated) {
        if (row >= actual.count() or !seedShared(&actual.at(row), expected)) return .Invalid;

        return if (initializers_shared) .Checked else .CheckInitializers;
    }

    const Input = std.meta.Child(rule.Input);
    const Headers = std.meta.Child(@FieldType(Input, "actual"));
    const Header = std.meta.Child(@FieldType(Input, "expected"));
    const Stores = @FieldType(Header, "stores");
    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    const input: Input = .{
        .actual = &.{
            .files = actual.files,
            .input_types = actual.input_types,
            .output_types = actual.output_types,
            .ownership = std.mem.sliceAsBytes(actual.ownership),
            .store_modes = std.mem.sliceAsBytes(actual.store_modes),
            .stores = zx.columns.slice(@FieldType(Headers, "stores"), actual.stores),
        },
        .expected = &.{
            .file_name = expected.file_name,
            .input_type = @backingInt(expected.input_type),
            .output_type = @backingInt(expected.output_type),
            .ownership = @backingInt(expected.output_ownership),
            .store_mode = @backingInt(expected.store_mode),
            .stores = zx.columns.pointer(Stores, &expected.stores),
        },
        .index = row,
        .initializers_shared = initializers_shared,
    };

    return zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch .Invalid;
}

fn seedShared(actual: *const ir.Function, expected: *const ir.Program) bool {
    if (actual.input_type != expected.input_type or actual.output_type != expected.output_type or
        actual.output_ownership != expected.output_ownership or actual.store_mode != expected.store_mode or
        actual.stores.count() != expected.stores.count()) return false;

    if (!std.mem.eql(u8, actual.file_name, expected.file_name)) return false;

    for (0..actual.stores.count()) |index| {
        const left = actual.stores.at(index);
        const right = expected.stores.at(index);

        if (!std.mem.eql(u8, left.path, right.path) or left.type_id != right.type_id or
            left.readable != right.readable or left.writable != right.writable) return false;
    }

    return true;
}
