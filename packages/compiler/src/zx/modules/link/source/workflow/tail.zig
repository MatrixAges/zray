const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const columns = @import("../../../artifact/materializing/publication/columns.zig");
const remap = @import("../../../artifact/nodes/remap.zig");

pub fn Storage(comptime Input: type) type {
    const Target = std.meta.Child(@FieldType(Input, "target"));
    const Empty = std.meta.Child(@FieldType(Input, "empty"));

    return struct {
        const empty: Empty = .{
            .control = zx.columns.pointer(@FieldType(Empty, "control"), (ir.ControlBody{}).control),
            .stores = zx.columns.pointer(@FieldType(Empty, "stores"), &ir.FunctionStorage.empty_stores),
        };
        tail: columns.Tail(Target),
        target: Target,
        lengths_array: [@typeInfo(ir.FunctionStorage).@"struct".field_names.len]*usize,
        lengths: zx.memory.ColumnLengths,
        completed: u64,
        pub fn init(self: *@This(), destination: *ir.FunctionStorage, temporary: std.mem.Allocator) Input {
            _ = temporary;

            self.tail.init(destination);

            self.target = .{ .storage = @ptrCast(&self.tail.storage), .shape = null };
            self.lengths_array = zx.memory.borrowColumnLengths(destination);
            self.lengths = &self.lengths_array;
            self.completed = 0;

            return .{
                .source = undefined,
                .mappings = undefined,
                .target = &self.target,
                .empty = &empty,
                .max_offset = std.math.maxInt(usize),
            };
        }

        pub fn deinit(self: *@This()) void {
            if (self.completed != 0) @import("../../../column_lengths.zig").publish(&self.lengths, self.completed);
        }
    };
}

pub fn borrowRoot(comptime Root: type, source: anytype, external: anytype, attributes: anytype, identity: ?[]const u8) Root {
    const view = ir.FunctionView.borrow(source);
    const native = view.signature.external;

    if (native) |value| external.* = @import("../../../artifact/materializing/external_host.zig").borrow(@TypeOf(external.*), value);

    attributes.* = remap.attributes(@TypeOf(attributes.*), &view, if (identity != null) .transaction else view.store_mode);

    return .{
        .file = identity orelse view.signature.file_name,
        .input_type = @backingInt(view.signature.input_type),
        .output_type = @backingInt(view.signature.output_type),
        .attributes = attributes,
        .native_module = if (native) |value| @backingInt(value.module) else null,
        .external = if (native != null) external else null,
        .stores = zx.columns.pointer(@FieldType(Root, "stores"), view.stores),
        .symbols = zx.columns.pointer(@FieldType(Root, "symbols"), view.symbols),
        .expressions = zx.columns.pointer(@FieldType(Root, "expressions"), view.expressions),
        .contracts = zx.columns.pointer(@FieldType(Root, "contracts"), view.contracts),
        .control = zx.columns.pointer(@FieldType(Root, "control"), view.body.control),
    };
}
