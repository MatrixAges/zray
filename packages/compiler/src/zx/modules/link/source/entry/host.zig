const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Nodes = @import("../../../artifact/nodes.zig");
const Surface = std.meta.Child(@import("generated_source_surface").Input);
const Input = std.meta.Child(@FieldType(Surface, "entry"));
const Candidate = std.meta.Child(@typeInfo(@FieldType(Input, "candidate")).optional.child);
const Body = std.meta.Child(@FieldType(Candidate, "source"));
const Mapping = std.meta.Child(@FieldType(Input, "functions"));

pub const Entry = struct {
    program: *const ir.Program,
    storage: *ir.FunctionStorage,
    nodes: *Nodes,
    temporary: std.mem.Allocator,
    candidate: Candidate = undefined,
    current: Body = undefined,
    last: Body = undefined,
    mapping: Mapping = undefined,
    pub fn bind(self: *Entry, tail: *const ir.FunctionTable, first: usize) Input {
        const program = self.program;
        const count = if (program.type_only or program.expressions.call_functions.len == 0) 0 else tail.count();

        if (count != 0) {
            const row = count - 1;

            self.current = body(ir.FunctionView.borrow(program));
            self.last = body(ir.FunctionView.at(tail, row));

            self.candidate = .{
                .source = &self.current,
                .last = &self.last,
                .calls = program.expressions.call_functions,
                .function = @intCast(first + row),
                .native = tail.native_modules[row] != null,
            };
        }

        self.mapping = @import("../../../artifact/nodes/remap.zig").idMapping(Mapping, self.nodes.functions);

        return .{
            .candidate = if (count != 0) &self.candidate else null,
            .type_only = program.type_only,
            .next = self.storage.count(),
            .functions = &self.mapping,
        };
    }
};

fn body(view: ir.FunctionView) Body {
    return .{
        .file = view.signature.file_name,
        .input_type = @backingInt(view.signature.input_type),
        .output_type = @backingInt(view.signature.output_type),
        .ownership = @backingInt(view.signature.output_ownership),
        .store_mode = @backingInt(view.store_mode),
        .root = if (view.body.root) |id| @backingInt(id) else null,
        .control = std.mem.asBytes(view.body.control),
        .stores = columns(view.stores),
        .symbols = columns(view.symbols),
        .expressions = columns(view.expressions),
        .contracts = columns(view.contracts),
    };
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
