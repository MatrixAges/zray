const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Types = @import("../analysis/types.zig");

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

pub fn kinds(comptime Kinds: type) Kinds {
    return .{ .callable = @backingInt(Member.Kind.callable), .intrinsic = @backingInt(Member.Kind.intrinsic) };
}

pub fn bindingFacts(comptime Facts: type, source: @FieldType(Facts, "members"), stores: []const *const ir.StoreTable) Facts {
    return .{ .members = source, .stores = zx.columns.slice(@FieldType(Facts, "stores"), stores), .void_type = @backingInt(Types.scalarId(.void)) };
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
