const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Project = @import("../../../project.zig").Project;
const Record = @import("../../../module_record.zig");
const tail = @import("../../../binding/publication/tail.zig");
const generated = @import("generated_project_execute_body");
const Input = std.meta.Child(@FieldType(std.meta.Child(generated.Input), "installation"));
const Layouts = @import("project_execution_abi").layouts.@"zig:memory/columns";
const Function = Layouts.FunctionBodyRow;
const Functions = std.meta.Child(@FieldType(Input, "functions"));
const target: ?*const Layouts.FunctionRow = null;
const body_shape: ?*const Function = null;
const native_shape: ?*const Layouts.FunctionNativeRow = null;
const growth = zx.memory.functionColumnGrowth(target, @as(?@FieldType(Functions, "growth"), null));
const body_layout = zx.memory.functionBodyLayout(body_shape, target, @as(?@FieldType(Functions, "body_layout"), null));
const native_layout = zx.memory.functionNativeLayout(native_shape, target, @as(?@FieldType(Functions, "native_layout"), null));
const empty_native = zx.memory.emptyFunctionNativeRecord(native_shape, @as(?@FieldType(Functions, "empty_native"), null));
const Rows = std.meta.Child(@FieldType(Input, "records"));
const Self = @This();

slots: [@typeInfo(Layouts.FunctionRow).@"struct".field_names.len]*anyopaque,
columns: zx.memory.ColumnSet,
functions: Functions,
request: std.meta.Child(@FieldType(Input, "request")),
function: Function,
modules: tail.Tail(Record, Rows, .{}),
cache: tail.Tail(usize, Rows, .{}),
record_rows: Rows,
cache_rows: Rows,
input: Input,
pub fn bind(self: *Self, project: *Project) void {
    self.slots = zx.memory.bindColumnSet(Layouts.FunctionRow, true, &project.functions);
    self.columns = &self.slots;

    self.functions = .{
        .storage = @ptrCast(&self.columns),
        .resource = @ptrCast(&project.allocator),
        .maximum_count = std.math.maxInt(u32),
        .growth = growth,
        .body_layout = body_layout,
        .native_layout = native_layout,
        .empty_native = empty_native,
    };

    self.modules.init(&project.modules);
    self.cache.init(&project.cache_records);

    self.record_rows = .{ .storage = @ptrCast(&self.modules.output.buffer), .used = @ptrCast(&self.modules.used) };
    self.cache_rows = .{ .storage = @ptrCast(&self.cache.output.buffer), .used = @ptrCast(&self.cache.used) };

    self.input = .{
        .request = &self.request,
        .functions = &self.functions,
        .function = @ptrCast(&self.function),
        .records = &self.record_rows,
        .cache = &self.cache_rows,
        .backing = @ptrCast(&project.arena.child_allocator),
    };
}

pub fn ownFunction(self: *Self, allocator: std.mem.Allocator, program: *const ir.Program) std.mem.Allocator.Error!void {
    const owned = try ir.FunctionStorage.ownDescriptors(allocator, @import("../../../function_body.zig").value(program.*));

    self.function = .{
        .files = program.file_name,
        .input_types = @backingInt(program.input_type),
        .output_types = @backingInt(program.output_type),
        .ownership = @fromBackingInt(@intCast(@backingInt(program.output_ownership))),
        .store_modes = @fromBackingInt(@intCast(@backingInt(program.store_mode))),
        .contracts = zx.columns.pointer(@FieldType(Function, "contracts"), owned.contracts),
        .symbols = zx.columns.pointer(@FieldType(Function, "symbols"), owned.symbols),
        .expressions = zx.columns.pointer(@FieldType(Function, "expressions"), owned.expressions),
        .control = zx.columns.pointer(@FieldType(Function, "control"), program.body.control),
        .roots = if (program.body.root) |id| @backingInt(id) else null,
        .stores = zx.columns.pointer(@FieldType(Function, "stores"), owned.stores.?),
    };
}

pub fn commit(self: *Self) void {
    self.modules.commit();
    self.cache.commit();
}
