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

const Target = struct {
    name: zx.memory.WriteColumn,
    kind: zx.memory.WriteColumn,
    input_type: zx.memory.WriteColumn,
    output_type: zx.memory.WriteColumn,
    source: zx.memory.WriteColumn,
    has_store: zx.memory.WriteColumn,
    fn borrow(rows: []Member) Target {
        const memory = zx.memory;

        return .{
            .name = memory.borrowWriteColumn([]const u8, "name", rows),
            .kind = memory.borrowWriteColumn(Member.Kind, "kind", rows),
            .input_type = memory.borrowNestedWriteColumn(ir.TypeId, &.{ "ports", "input_type" }, rows),
            .output_type = memory.borrowNestedWriteColumn(ir.TypeId, &.{ "ports", "output_type" }, rows),
            .source = memory.borrowWriteColumn([]const u8, "source", rows),
            .has_store = memory.borrowWriteColumn(u8, "has_store", rows),
        };
    }
    fn view(self: *const Target, comptime Shape: type) Shape {
        var result: Shape = undefined;

        inline for (@typeInfo(Shape).@"struct".field_names) |name| {
            @field(result, name) = @ptrCast(&@field(self, name));
        }

        return result;
    }
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
    const memory = zx.memory;
    const own: usize = @intFromBool(!signature.type_only);
    const declaration: Declaration = .{ .input_type = @backingInt(signature.ports.input_type), .output_type = @backingInt(signature.ports.output_type), .has_store = signature.has_store };
    const target = std.mem.sliceAsBytes(members[own..][0..forwarded.len]);
    const output = Target.borrow(members);
    const Bindings = std.meta.Child(@FieldType(Input, "bindings"));
    const Facts = std.meta.Child(@FieldType(Bindings, "facts"));
    const MemberSource = std.meta.Child(@FieldType(Facts, "members"));
    const readable = FunctionImport.Readable.borrowRows(native);

    const input: Input = .{
        .target = &output.view(std.meta.Child(@FieldType(Input, "target"))),
        .callable = if (own != 0) &declaration else null,
        .kinds = &kinds(std.meta.Child(@FieldType(Input, "kinds"))),
        .forwarded = &.{ .rows = std.mem.sliceAsBytes(forwarded), .target = @ptrCast(&target), .count = forwarded.len },
        .bindings = &.{
            .names = @ptrCast(&memory.borrowTextColumn("name", native)),
            .facts = &bindingFacts(Facts, &.{ .named = &readable.view(std.meta.Child(@FieldType(MemberSource, "named"))), .fallback = null }, stores),
            .count = native.len,
        },
    };

    try writeMembers(rule, allocator, &input);
}

pub fn kinds(comptime Kinds: type) Kinds {
    return .{ .callable = @backingInt(Member.Kind.callable), .intrinsic = @backingInt(Member.Kind.intrinsic) };
}

pub fn bindingFacts(comptime Facts: type, source: @FieldType(Facts, "members"), stores: []const *const ir.StoreTable) Facts {
    return .{ .members = source, .stores = zx.columns.slice(@FieldType(Facts, "stores"), stores), .void_type = @backingInt(Types.scalarId(.void)) };
}

fn writeMembers(comptime Rule: type, allocator: std.mem.Allocator, input: Rule.Input) std.mem.Allocator.Error!void {
    if (!(zx.columns.invoke(Rule.executeValue, allocator, input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
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
