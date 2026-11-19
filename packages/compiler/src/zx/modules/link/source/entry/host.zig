const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Nodes = @import("../../../artifact/nodes.zig");
const rule = @import("generated_source_link_entry");
const Input = std.meta.Child(rule.Input);
const Candidate = std.meta.Child(@typeInfo(@FieldType(Input, "candidate")).optional.child);
const Body = std.meta.Child(@FieldType(Candidate, "source"));
const Mapping = std.meta.Child(@FieldType(Input, "functions"));
const Error = @import("../../program.zig").Error;

pub fn publish(program: *const ir.Program, tail: *const ir.FunctionTable, first: usize, storage: *ir.FunctionStorage, nodes: *Nodes, temporary: std.mem.Allocator) Error!?ir.FunctionId {
    var candidate: Candidate = undefined;
    var current: Body = undefined;
    var last: Body = undefined;
    const count = if (program.type_only or program.expressions.call_functions.len == 0) 0 else tail.count();

    if (count != 0) {
        const row = count - 1;

        current = .{
            .file = program.file_name,
            .input_type = @backingInt(program.input_type),
            .output_type = @backingInt(program.output_type),
            .ownership = @backingInt(program.output_ownership),
            .store_mode = @backingInt(program.store_mode),
            .root = if (program.body.root) |id| @backingInt(id) else null,
            .control = std.mem.asBytes(program.body.control),
            .stores = columns(&program.stores),
            .symbols = columns(&program.symbols),
            .expressions = columns(&program.expressions),
            .contracts = columns(&program.contracts),
        };

        last = .{
            .file = tail.files[row],
            .input_type = tail.input_types[row],
            .output_type = tail.output_types[row],
            .ownership = @backingInt(tail.ownership[row]),
            .store_mode = @backingInt(tail.store_modes[row]),
            .root = tail.roots[row],
            .control = std.mem.asBytes(tail.control[row]),
            .stores = columns(tail.stores[row]),
            .symbols = columns(tail.symbols[row]),
            .expressions = columns(tail.expressions[row]),
            .contracts = columns(tail.contracts[row]),
        };

        candidate = .{
            .source = &current,
            .last = &last,
            .calls = program.expressions.call_functions,
            .function = @intCast(first + row),
            .native = tail.native_modules[row] != null,
        };
    }

    const functions = @import("../../../artifact/nodes/remap.zig").idMapping(Mapping, nodes.functions);

    const input: Input = .{
        .candidate = if (count != 0) &candidate else null,
        .type_only = program.type_only,
        .next = storage.count(),
        .functions = &functions,
    };

    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    const output = zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    if (output.append) try nodes.appendProgram(storage, program, temporary);

    return if (output.function) |id| @fromBackingInt(id) else null;
}

// The views are used only for pointer and length comparison. The payload stays in its original columns.
fn columns(table: anytype) []const []const u8 {
    const Table = std.meta.Child(@TypeOf(table));
    const fields = @typeInfo(Table).@"struct".field_types;

    comptime {
        for (fields) |Slice| {
            if (@typeInfo(Slice).pointer.size != .slice or @sizeOf(Slice) != @sizeOf([]const u8) or
                @alignOf(Slice) != @alignOf([]const u8)) @compileError("Expected a table of slice descriptors");
        }

        if (@sizeOf(Table) != fields.len * @sizeOf([]const u8)) @compileError("Unexpected column descriptor layout");
    }

    const descriptors: [*]const []const u8 = @ptrCast(table);

    return descriptors[0..fields.len];
}
