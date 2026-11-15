const std = @import("std");
const ir = @import("../ir.zig");
const Self = @This();

files: []const []const u8 = &.{},
input_types: []const u32 = &.{},
output_types: []const u32 = &.{},
ownership: []const ir.SymbolTable.Ownership = &.{},
store_modes: []const ir.StoreMode = &.{},
contracts: []const *const ir.ContractTable = &.{},
native_inputs: []const ?[]const ?[]const u8 = &.{},
native_modules: []const ?u32 = &.{},
native_members: []const []const []const u8 = &.{},
native_exports: []const ?[]const u8 = &.{},
native_allocators: []const bool = &.{},
native_io: []const bool = &.{},
native_process: []const bool = &.{},
native_tuples: []const bool = &.{},
native_fallible: []const bool = &.{},
native_errors: []const ?[]const []const u8 = &.{},
native_concurrent: []const bool = &.{},
symbols: []const *const ir.SymbolTable = &.{},
expressions: []const *const ir.ExpressionTable = &.{},
control: []const *const ir.ControlTable = &.{},
roots: []const ?u32 = &.{},
stores: []const *const ir.StoreTable = &.{},
pub fn count(self: Self) usize {
    return self.files.len;
}

pub fn at(self: Self, index: usize) ir.Function {
    const signature = ir.SignatureTable.read(&self, index);

    return .{
        .file_name = signature.file_name,
        .input_type = signature.input_type,
        .output_type = signature.output_type,
        .output_ownership = signature.output_ownership,
        .store_mode = self.store_modes[index],
        .contracts = self.contracts[index].*,
        .external = signature.external,
        .symbols = self.symbols[index].*,
        .expressions = self.expressions[index].*,
        .body = self.controlAt(index),
        .stores = self.stores[index].*,
    };
}

pub fn controlAt(self: *const Self, index: usize) ir.ControlBody {
    return .{
        .control = self.control[index],
        .root = if (self.roots[index]) |id| @fromBackingInt(id) else null,
    };
}

pub fn prefix(self: Self, len: usize) Self {
    var result: Self = .{};

    inline for (@typeInfo(Self).@"struct".field_names) |name| @field(result, name) = @field(self, name)[0..len];

    return result;
}

pub fn suffix(self: Self, first: usize) Self {
    var result: Self = .{};

    inline for (@typeInfo(Self).@"struct".field_names) |name| @field(result, name) = @field(self, name)[first..];

    return result;
}

pub fn validStructure(self: Self) bool {
    if (self.count() > std.math.maxInt(u32)) return false;

    inline for (@typeInfo(Self).@"struct".field_names) |name| {
        if (@field(self, name).len != self.count()) return false;
    }

    for (self.native_modules, 0..) |module, index| {
        if (module != null) continue;
        if (self.native_inputs[index] != null or self.native_members[index].len != 0 or self.native_exports[index] != null or self.native_allocators[index] or self.native_io[index] or self.native_process[index] or self.native_tuples[index] or self.native_fallible[index] or self.native_errors[index] != null or self.native_concurrent[index]) return false;
    }

    return true;
}

pub fn snapshot(self: Self, allocator: std.mem.Allocator) std.mem.Allocator.Error!Self {
    var result: Self = .{};

    copy: {
        inline for (@typeInfo(Self).@"struct".field_names) |name| {
            const source = @field(self, name);

            @field(result, name) = allocator.dupe(std.meta.Elem(@TypeOf(source)), source) catch break :copy;
        }

        return result;
    }

    inline for (@typeInfo(Self).@"struct".field_names) |name| allocator.free(@field(result, name));

    return error.OutOfMemory;
}

pub fn get(self: Self, id: ir.FunctionId) ir.Function {
    return self.at(@backingInt(id));
}

pub fn fromValues(allocator: std.mem.Allocator, values: []const ir.Function) std.mem.Allocator.Error!Self {
    var storage: @import("storage.zig") = .{};

    errdefer storage.deinit(allocator);

    for (values) |value| try storage.append(allocator, value);

    return storage.finish(allocator);
}
