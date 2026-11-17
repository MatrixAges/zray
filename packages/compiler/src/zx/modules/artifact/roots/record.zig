const std = @import("std");
const ir = @import("zx").ir;
const names = @import("../../../ir/canonical/validation/names/view.zig");
const Record = @import("../../module_record.zig");
const RecordColumns = @import("../../module_record/columns.zig");
const Binding = @import("../../function_import.zig");
const Error = @import("../model.zig").Error;
const generated = @import("generated_artifact_root_bindings");
const Parameter = @typeInfo(@TypeOf(generated.executeValue)).@"fn".param_types[1].?;
const indirect = @typeInfo(Parameter) == .pointer;
const Input = if (indirect) std.meta.Child(Parameter) else Parameter;
const Row = std.meta.Child(@FieldType(Input, "bindings"));
const Columns = std.meta.Child(@typeInfo(@FieldType(Input, "columns")).optional.child);

pub fn View(comptime Target: type) type {
    const Aliases = std.meta.Child(@FieldType(Target, "exports"));
    const ColumnsView = std.meta.Child(@FieldType(Target, "constant_exports"));
    const Dependencies = std.meta.Child(@FieldType(Target, "dependencies"));

    return struct {
        export_rows: names.Rows,
        import_rows: names.Rows,
        exports: Aliases,
        imports: Aliases,
        dependency_columns: RecordColumns,
        dependencies: Dependencies,
        constants: ColumnsView,
        constant_imports: ColumnsView,
        plan: Target,
        pub fn init(self: *@This(), allocator: std.mem.Allocator, record: Record) Error!void {
            const bindings = [2][]const Binding{ record.function_imports, record.reexports.functions };
            const ordinary_count = try ports(bindings, null);
            const port_count = std.math.mul(usize, ordinary_count, 2) catch return error.OutOfMemory;
            const types = try allocator.alloc(u32, port_count);
            const function_inputs = types[0..ordinary_count];
            const function_outputs = types[ordinary_count..];
            const function_ids = try allocator.alloc(u32, ordinary_count);

            _ = try ports(bindings, &.{
                .ids = @ptrCast(&function_ids),
                .inputs = @ptrCast(&function_inputs),
                .outputs = @ptrCast(&function_outputs),
            });

            self.dependency_columns = .borrow(record.imports);
            self.dependencies = self.dependency_columns.view(Dependencies);
            self.export_rows = names.borrow(record.exports);
            self.import_rows = names.borrow(record.type_imports);
            self.exports = names.view(Aliases, &self.export_rows);
            self.imports = names.view(Aliases, &self.import_rows);
            self.constants = constants(record.constant_exports, ColumnsView);
            self.constant_imports = constants(record.constant_imports, ColumnsView);

            self.plan = .{
                .path = record.path,
                .start = record.type_range.start,
                .end = record.type_range.end,
                .exports = &self.exports,
                .constant_exports = &self.constants,
                .constant_imports = &self.constant_imports,
                .type_imports = &self.imports,
                .function_ids = function_ids,
                .function_inputs = function_inputs,
                .function_outputs = function_outputs,
                .dependencies = &self.dependencies,
                .has_body = record.body != .types,
                .body_function = if (record.own_function) |id| @backingInt(id) else if (record.body == .function) @backingInt(record.body.function) else null,
            };
        }
    };
}

fn constants(source: []const ir.Constant, comptime Target: type) Target {
    comptime std.debug.assert(@typeInfo(ir.TypeId).@"enum".tag_type == u32);

    return .{
        .data = std.mem.sliceAsBytes(source),
        .rows = source.len,
        .stride = @sizeOf(ir.Constant),
        .field = @offsetOf(ir.Constant, "type_id"),
        .little_endian = @import("builtin").target.cpu.arch.endian() == .little,
    };
}

fn ports(groups: [2][]const Binding, columns: ?*const Columns) Error!usize {
    const batch_size = @import("../../package_scope.zig").lookup_batch_size;
    var buffer: [batch_size]Row = undefined;
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    var count: u64 = 0;

    for (groups) |group| {
        var remaining = group;

        while (remaining.len != 0) {
            const size = @min(remaining.len, batch_size);

            for (remaining[0..size], buffer[0..size]) |*binding, *row| {
                row.* = .{
                    .id = if (binding.id) |id| @backingInt(id) else null,
                    .input_type = if (binding.input_type) |id| @backingInt(id) else null,
                    .output_type = if (binding.output_type) |id| @backingInt(id) else null,
                    .intrinsic = if (binding.intrinsic) |value| @backingInt(value) else null,
                };
            }

            const input: Input = .{ .bindings = buffer[0..size], .columns = columns, .first = count };

            count = (generated.executeValue(empty.allocator(), if (indirect) &input else input) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidModule,
            }) orelse return error.InvalidModule;

            remaining = remaining[size..];
        }
    }

    return @intCast(count);
}
