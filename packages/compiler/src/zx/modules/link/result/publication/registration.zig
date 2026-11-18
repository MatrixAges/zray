const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const generated = @import("generated_artifact_entry_registration");
const Input = std.meta.Child(generated.Input);

pub fn append(allocator: std.mem.Allocator, functions: *ir.FunctionStorage, value: *const ir.Program, descriptors: ir.FunctionStorage.Descriptors) std.mem.Allocator.Error!void {
    var view: View(Input) = undefined;

    view.init(&allocator, functions, value, descriptors);

    generated.executeIn(allocator, &view.input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
}

pub fn View(comptime Registration: type) type {
    const Destination = std.meta.Child(@FieldType(Registration, "destination"));
    const Row = std.meta.Child(@FieldType(Registration, "row"));
    const fields = @typeInfo(Row).@"struct".field_names;

    return struct {
        const Self = @This();
        slots: [fields.len]*anyopaque,
        columns: zx.memory.ColumnSet,
        destination: Destination,
        row: Row,
        input: Registration,
        pub fn init(self: *Self, allocator: *const std.mem.Allocator, functions: *ir.FunctionStorage, value: anytype, descriptors: ir.FunctionStorage.Descriptors) void {
            self.slots = zx.memory.bindColumnSet(Row, true, functions);
            self.columns = &self.slots;

            self.destination = .{
                .storage = @ptrCast(&self.columns),
                .maximum_count = std.math.maxInt(u32),
                .shape = null,
                .resource = @ptrCast(allocator),
            };

            self.row = .{
                .files = value.file_name,
                .input_types = @backingInt(value.input_type),
                .output_types = @backingInt(value.output_type),
                .ownership = @fromBackingInt(@intCast(@backingInt(value.output_ownership))),
                .store_modes = @fromBackingInt(@intCast(@backingInt(value.store_mode))),
                .contracts = @ptrCast(descriptors.contracts),
                .native_inputs = null,
                .native_modules = null,
                .native_members = &.{},
                .native_exports = null,
                .native_allocators = false,
                .native_io = false,
                .native_process = false,
                .native_tuples = false,
                .native_fallible = false,
                .native_errors = null,
                .native_concurrent = false,
                .symbols = @ptrCast(descriptors.symbols),
                .expressions = @ptrCast(descriptors.expressions),
                .control = @ptrCast(value.body.control),
                .roots = if (value.body.root) |id| @backingInt(id) else null,
                .stores = @ptrCast(descriptors.stores orelse &ir.FunctionStorage.empty_stores),
            };

            self.input = .{ .destination = &self.destination, .row = &self.row };
        }
    };
}
