const std = @import("std");
const zx = @import("zx");
const memory = zx.memory;
const ir = zx.ir;
const Error = @import("../model.zig").Error;
const TypePrefix = @import("../../../ir/validate.zig").TypePrefix;
const PrefixState = @import("../../../ir/validate.zig").Verified;
const validation = @import("generated_ir_validation");
const verify_entry = @import("generated_artifact_validation");
const Validation = std.meta.Child(validation.Input);
const Context = std.meta.Child(@FieldType(Validation, "context"));
const Table = std.meta.Child(@FieldType(Context, "table"));
const Complete = std.meta.Child(@FieldType(Context, "functions"));
pub const Input = std.meta.Child(verify_entry.Input);
pub const Verified = @typeInfo(verify_entry.Output).optional.child;

pub const State = struct {
    types: *ir.TypeStorage,
    functions: *ir.FunctionStorage,
    native_modules: *const ir.NativeModuleTable,
    verified: PrefixState = .{},
};

pub fn publicationError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => error.OutOfMemory,
        else => error.InvalidModule,
    };
}

pub fn verificationError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => error.OutOfMemory,
        else => error.InvalidIr,
    };
}

pub const View = struct {
    const Views = std.meta.Child(@FieldType(Input, "views"));
    const Base = std.meta.Child(@FieldType(Views, "context"));
    const Prefix = std.meta.Child(@typeInfo(@FieldType(Base, "verified_types")).optional.child);
    const Exports = std.meta.Child(@FieldType(Input, "exports"));
    const Constants = std.meta.Child(@typeInfo(@FieldType(Input, "constant_exports")).optional.child);

    table: Table,
    functions: Complete,
    type_slots: [@typeInfo(Table).@"struct".field_names.len]*anyopaque,
    function_slots: [@typeInfo(Complete).@"struct".field_names.len]*anyopaque,
    type_storage: memory.ColumnSet,
    function_storage: memory.ColumnSet,
    prefix: Prefix,
    base: Base,
    exports: Exports,
    reads: [3]memory.ReadColumn,
    growth: memory.RowGrowth,
    constants: Constants,
    views: Views,
    input: Input,
    pub fn init(self: *View, state: State, surface: anytype, scratch: std.mem.Allocator) void {
        _ = scratch;
        self.type_slots = memory.bindColumnSet(Table, false, state.types);
        self.function_slots = memory.bindColumnSet(Complete, false, state.functions);
        self.type_storage = &self.type_slots;
        self.function_storage = &self.function_slots;

        const verified = state.verified;

        if (verified.types) |prefix| self.prefix = zx.columns.view(Prefix, prefix);

        self.base = .{
            .modules = zx.columns.pointer(@FieldType(Base, "modules"), state.native_modules),
            .max_offset = std.math.maxInt(usize),
            .scalar_count = std.enums.values(ir.Scalar).len,
            .maximum_count = std.math.maxInt(u32),
            .verified = verified.functions,
            .verified_types = if (verified.types != null) &self.prefix else null,
            .verified_native = verified.native,
        };

        self.exports = .{ .rows = @ptrCast(&surface.export_target), .length = surface.export_source.length };
        self.growth = .{ .target = &surface.constant_output.buffer, .reads = &self.reads };

        self.constants = .{
            .names = @ptrCast(&self.reads[0]),
            .types = @ptrCast(&self.reads[1]),
            .values = @ptrCast(&self.reads[2]),
            .count = surface.constant_source.count,
        };

        self.views = .{
            .context = &self.base,
            .type_storage = @ptrCast(&self.type_storage),
            .type_view = @ptrCast(&self.table),
            .function_storage = @ptrCast(&self.function_storage),
            .function_view = @ptrCast(&self.functions),
            .constants = if (self.constants.count != 0) @ptrCast(&self.growth) else null,
        };

        self.input = .{
            .version = zx.ir_version,
            .exports = &self.exports,
            .constant_exports = if (self.constants.count != 0) &self.constants else null,
            .views = &self.views,
            .program = undefined,
            .empty = undefined,
        };
    }

    pub fn execute(self: *View, scratch: std.mem.Allocator, program: anytype, empty: anytype) Error!Verified {
        self.input.program = zx.columns.bridge(@FieldType(Input, "program"), scratch, program) catch |err| return verificationError(err);
        self.input.empty = zx.columns.bridge(@FieldType(Input, "empty"), scratch, empty) catch |err| return verificationError(err);
        const verified = verify_entry.executeIn(scratch, &self.input) catch |err| return verificationError(err);

        return verified orelse return error.InvalidIr;
    }
};

pub fn applyPrefix(verified: Verified) PrefixState {
    return .{
        .functions = @intCast(verified.functions),
        .types = zx.columns.view(TypePrefix, verified.types),
        .native = verified.native,
    };
}
