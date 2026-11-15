const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const generated = @import("rx_options").generated_graph;

pub fn shared(actual: *const ir.FunctionTable, row: usize, expected: *const ir.Program) bool {
    if (comptime !generated) return seedShared(&actual.at(row), expected);

    const rule = @import("generated_rx_program_check_function");
    const Input = std.meta.Child(rule.Input);
    const Header = std.meta.Child(@FieldType(Input, "actual"));
    const Stores = @FieldType(Header, "stores");
    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    const input: Input = .{
        .actual = &.{
            .file_name = actual.files[row],
            .input_type = actual.input_types[row],
            .output_type = actual.output_types[row],
            .ownership = @backingInt(actual.ownership[row]),
            .store_mode = @backingInt(actual.store_modes[row]),
            .stores = zx.columns.pointer(Stores, actual.stores[row]),
        },
        .expected = &.{
            .file_name = expected.file_name,
            .input_type = @backingInt(expected.input_type),
            .output_type = @backingInt(expected.output_type),
            .ownership = @backingInt(expected.output_ownership),
            .store_mode = @backingInt(expected.store_mode),
            .stores = zx.columns.pointer(Stores, &expected.stores),
        },
    };

    return zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch unreachable;
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
