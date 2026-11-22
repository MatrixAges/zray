const std = @import("std");
const ir = @import("../../ir.zig");
const columns = @import("../../columns.zig");
const memory = @import("memory");
const generated = @import("generated_function_table_publish");
const Input = std.meta.Child(generated.Input);
const Body = std.meta.Child(@FieldType(Input, "body"));
const Native = std.meta.Child(@typeInfo(@FieldType(Input, "native")).optional.child);
const Row = @import("../../ir/schema.zig").Columns.FunctionRow;

pub fn append(storage: *ir.FunctionStorage, signature: ir.Signature, store_mode: ir.StoreMode, control: ir.ControlBody, owned: ir.FunctionStorage.Descriptors) void {
    const slots = memory.bindColumnSet(Row, true, storage);
    const target: memory.ColumnSet = &slots;

    const body: Body = .{
        .files = signature.file_name,
        .input_types = @backingInt(signature.input_type),
        .output_types = @backingInt(signature.output_type),
        .ownership = @fromBackingInt(@intCast(@backingInt(signature.output_ownership))),
        .store_modes = @fromBackingInt(@intCast(@backingInt(store_mode))),
        .contracts = columns.pointer(@FieldType(Body, "contracts"), owned.contracts),
        .symbols = columns.pointer(@FieldType(Body, "symbols"), owned.symbols),
        .expressions = columns.pointer(@FieldType(Body, "expressions"), owned.expressions),
        .control = columns.pointer(@FieldType(Body, "control"), control.control),
        .roots = if (control.root) |id| @backingInt(id) else null,
        .stores = columns.pointer(@FieldType(Body, "stores"), owned.stores orelse &ir.FunctionStorage.empty_stores),
    };

    const native = if (signature.external) |external| Native{
        .native_inputs = if (external.input) |input| input.names else null,
        .native_modules = @backingInt(external.module),
        .native_members = external.member,
        .native_exports = external.export_name,
        .native_allocators = external.allocator_argument,
        .native_io = external.io_argument,
        .native_process = external.process_argument,
        .native_tuples = external.expand_tuple,
        .native_fallible = external.fallible,
        .native_errors = external.errors,
        .native_concurrent = external.concurrent,
    } else null;

    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    generated.executeIn(scratch.allocator(), &Input{
        .storage = @ptrCast(&target),
        .body = &body,
        .native = if (native) |*value| value else null,
    }) catch unreachable;
}
