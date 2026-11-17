const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Types = @import("../analysis/types.zig");
const FunctionImport = @import("function_import.zig");

pub const Ports = struct {
    input_type: ir.TypeId,
    output_type: ir.TypeId,
};

pub const Member = struct {
    pub const Kind = enum(u8) { callable, deferred, intrinsic };

    name: []const u8,
    kind: Kind,
    ports: Ports = .{ .input_type = Types.scalarId(.void), .output_type = Types.scalarId(.void) },
    source: []const u8 = &.{},
    has_store: bool = false,
};

pub const Result = struct {
    ports: Ports,
    exports: []const ir.Export,
    constant_exports: []const ir.Constant = &.{},
    members: []const Member = &.{},
    type_only: bool,
    has_store: bool,
    has_deferred_source: bool = false,
    deferred_source: []const u8 = &.{},
};

pub fn publishMembers(allocator: std.mem.Allocator, signature: *const Result, stores: []const *const ir.StoreTable, forwarded: []const Member, native: []const FunctionImport, members: []Member) std.mem.Allocator.Error!void {
    if (members.len == 0) return;

    const rule = @import("generated_project_signature_members");
    const Input = std.meta.Child(rule.Input);
    const Declaration = std.meta.Child(@typeInfo(@FieldType(Input, "callable")).optional.child);
    const Bindings = std.meta.Child(@FieldType(Input, "bindings"));
    const memory = zx.memory;
    const own: usize = @intFromBool(!signature.type_only);
    const declaration: Declaration = .{ .input_type = @backingInt(signature.ports.input_type), .output_type = @backingInt(signature.ports.output_type), .has_store = signature.has_store };
    const target = std.mem.sliceAsBytes(members[own..][0..forwarded.len]);

    const input: Input = .{
        .target = &.{
            .name = @ptrCast(&memory.borrowWriteColumn([]const u8, "name", members)),
            .kind = @ptrCast(&memory.borrowWriteColumn(Member.Kind, "kind", members)),
            .input_type = @ptrCast(&memory.borrowNestedWriteColumn(ir.TypeId, &.{ "ports", "input_type" }, members)),
            .output_type = @ptrCast(&memory.borrowNestedWriteColumn(ir.TypeId, &.{ "ports", "output_type" }, members)),
            .source = @ptrCast(&memory.borrowWriteColumn([]const u8, "source", members)),
            .has_store = @ptrCast(&memory.borrowWriteColumn(u8, "has_store", members)),
        },
        .callable = if (own != 0) &declaration else null,
        .kinds = &.{ .callable = @backingInt(Member.Kind.callable), .intrinsic = @backingInt(Member.Kind.intrinsic) },
        .forwarded = &.{ .rows = std.mem.sliceAsBytes(forwarded), .target = @ptrCast(&target), .count = forwarded.len },
        .bindings = &.{
            .names = @ptrCast(&memory.borrowTextColumn("name", native)),
            .ids = @ptrCast(&memory.borrowOptionalU32Column("id", native)),
            .inputs = @ptrCast(&memory.borrowOptionalU32Column("input_type", native)),
            .outputs = @ptrCast(&memory.borrowOptionalU32Column("output_type", native)),
            .intrinsics = @ptrCast(&memory.borrowOptionalU8Column("intrinsic", native)),
            .stores = zx.columns.slice(@FieldType(Bindings, "stores"), stores),
            .void_type = @backingInt(Types.scalarId(.void)),
            .count = native.len,
        },
    };

    if (!(zx.columns.invoke(rule.executeValue, allocator, &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.IndexOutOfBounds => unreachable,
    })) unreachable;
}

pub fn ports(types: *Types, program: anytype) zx.Error!Ports {
    const span = if (program.body) |body| body.span else zx.Span{ .start = 0, .end = 0 };

    return .{
        .input_type = if (program.body != null) try types.named(.{ .text = "Input", .span = span }) else Types.scalarId(.void),
        .output_type = if (program.body != null) try types.named(.{ .text = "Output", .span = span }) else Types.scalarId(.void),
    };
}

pub fn exports(types: *Types, view: anytype) zx.Error![]const ir.Export {
    const declarations = view.declarations();
    const result = try types.allocator.alloc(ir.Export, declarations.count());
    var iterator = declarations.iterator();

    for (result) |*item| {
        const declaration = iterator.next().?;

        item.* = .{
            .name = try types.allocator.dupe(u8, declaration.name.text),
            .type_id = try types.named(declaration.name),
        };
    }

    return result;
}

pub fn resolve(types: *Types, program: anytype, view: anytype, constants: []const ir.Constant) zx.Error!Result {
    const signature = try ports(types, program);

    return .{
        .ports = signature,
        .exports = try exports(types, view),
        .constant_exports = (try @import("../analysis/constants/declarations/seed.zig").apply(types, program.constants, constants)).exports,
        .type_only = program.body == null,
        .has_store = program.has_store,
    };
}
