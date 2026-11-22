const std = @import("std");
const ir = @import("zx").ir;
const projection = @import("borrow.zig");
const Initializer = @import("../../modules/source_store_initializer.zig");
const empty_contracts: ir.ContractTable = .{};

pub fn matches(left: *const ir.Function, right: *const ir.Function, left_version: u32, right_version: u32, mapping: ?[]const ir.TypeId) bool {
    const seed = @import("initializer_seed.zig");

    if (left_version != right_version) return false;

    return if (mapping) |map| seed.source(left, right, map) else seed.linked(left, right);
}

pub fn source(table: *const ir.FunctionTable, row: u32, initial: Initializer.Borrowed, mapping: []const u32) bool {
    const program = initial.program;
    const entry = @import("generated_library_initializer_compare");
    const Input = std.meta.Child(entry.Input);
    const Pair = std.meta.Child(@FieldType(Input, "header"));
    const Header = std.meta.Child(@FieldType(Pair, "left"));
    const Native = std.meta.Child(@typeInfo(@FieldType(Header, "native")).optional.child);
    const Types = std.meta.Child(@FieldType(Input, "types"));
    const Ids = std.meta.Child(@FieldType(Types, "symbols"));
    const Columns = std.meta.Child(@FieldType(Input, "columns"));
    const left_native = if (ir.SignatureTable.readExternal(table, row)) |value| native(Native, value) else null;

    const left_header: Header = .{
        .version = initial.schema_version,
        .name = table.files[row],
        .transaction = table.store_modes[row] == .transaction,
        .ownership = @fromBackingInt(@backingInt(table.ownership[row])),
        .input_type = table.input_types[row],
        .output_type = table.output_types[row],
        .root = table.roots[row],
        .native = if (left_native != null) &left_native.? else null,
    };

    const right_header: Header = .{
        .version = initial.schema_version,
        .name = initial.identity,
        .transaction = true,
        .ownership = switch (program.output_ownership) {
            .copy => .Copy,
            .borrowed => .Borrowed,
            .owned => .Owned,
        },
        .input_type = @backingInt(program.input_type),
        .output_type = @backingInt(program.output_type),
        .root = if (program.body.root) |root| @backingInt(root) else null,
        .native = null,
    };

    const headers: Pair = .{ .left = &left_header, .right = &right_header, .mapping = mapping };
    const symbols = ids(Ids, table.symbols[row].types, program.symbols.types);
    const expressions = ids(Ids, table.expressions[row].types, program.expressions.types);
    const types: Types = .{ .symbols = &symbols, .expressions = &expressions, .mapping = mapping };
    const right_control = if (program.body.root == null) &ir.ControlTable{} else program.body.control;
    var left_columns: projection.Function = undefined;
    var right_columns: projection.Function = undefined;

    left_columns.borrow(.{ table.stores[row], table.symbols[row], table.expressions[row], table.control[row], table.contracts[row] });

    right_columns.borrow(.{ &ir.FunctionStorage.empty_stores, &program.symbols, &program.expressions, right_control, &empty_contracts });

    const input_left = left_columns.view(std.meta.Child(@FieldType(Columns, "left")));
    const input_right = right_columns.view(std.meta.Child(@FieldType(Columns, "right")));
    const columns: Columns = .{ .left = &input_left, .right = &input_right, .masks = &projection.Function.masks };
    const Contracts = std.meta.Child(@typeInfo(@FieldType(Input, "contracts")).optional.child);
    var contract_view: @import("referenced/host.zig").ContractView(Contracts) = undefined;
    const nested = table.contracts[row].count() != 0;

    if (nested) contract_view.init(table.contracts[row], &empty_contracts);

    const input: Input = .{
        .header = &headers,
        .types = &types,
        .columns = &columns,
        .contracts = if (nested) &contract_view.input else null,
    };

    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    return entry.executeIn(fixed.allocator(), &input) catch unreachable;
}

fn native(comptime Target: type, value: ir.External) Target {
    return .{
        .module_id = @backingInt(value.module),
        .member = value.member,
        .export_name = value.export_name,
        .allocator = value.allocator_argument,
        .io = value.io_argument,
        .process = value.process_argument,
        .tuple = value.expand_tuple,
        .fallible = value.fallible,
        .concurrent = value.concurrent,
        .input = if (value.input) |input| input.names else null,
        .errors = value.errors,
    };
}

fn ids(comptime Target: type, left: []const u32, right: []const u32) Target {
    return .{ .left = left, .right = right, .left_bytes = std.mem.sliceAsBytes(left), .right_bytes = std.mem.sliceAsBytes(right) };
}
