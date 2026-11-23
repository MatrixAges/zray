const std = @import("std");
const zx = @import("zx");
const memory = zx.memory;
const project = @import("../../../project.zig");
const Signature = @import("../../../source_signature.zig");
const FunctionImport = @import("../../../function_import.zig");
const generated = @import("generated_project_signature_publish");
const Input = std.meta.Child(generated.Input);
const Exports = std.meta.Child(@FieldType(Input, "exports"));

fn Rows(comptime Row: type, comptime Shape: type) type {
    return struct {
        const Self = @This();
        const Storage = memory.RowOutput(Row, struct { name: *const anyopaque }, .{});
        storage: Storage,
        name: memory.TextColumn,
        reads: memory.RowGrowth,
        fn borrow(self: *Self, own: []const Row, forwarded: []const Row) Shape {
            self.storage.init();

            self.name = memory.borrowTextColumn("name", if (own.len == 0) forwarded else own);
            self.reads = .{ .target = &self.storage.buffer, .reads = @as(*[1]memory.ReadColumn, @ptrCast(&self.name)) };

            return .{
                .own = std.mem.sliceAsBytes(own),
                .forwarded = std.mem.sliceAsBytes(forwarded),
                .stride = @sizeOf(Row),
                .storage = @ptrCast(&self.storage.buffer),
                .buffer = @ptrCast(&self.storage.buffer.bytes),
                .reads = @ptrCast(&self.reads),
                .names = @ptrCast(&self.name),
            };
        }
    };
}

const Members = struct {
    const Shape = std.meta.Child(@FieldType(Input, "members"));
    const Target = std.meta.Child(@FieldType(Shape, "target"));

    const Storage = memory.RowOutput(Signature.Member, Target, .{
        .input_type = &.{ "ports", "input_type" },
        .output_type = &.{ "ports", "output_type" },
    });

    const kinds = Signature.kinds(std.meta.Child(@FieldType(Shape, "kinds")));

    storage: Storage,
    columns: [@typeInfo(Target).@"struct".field_names.len]memory.ReadColumn,
    reads: memory.RowGrowth,
    fn column(self: *const Members, comptime name: []const u8) *const memory.ReadColumn {
        return &self.columns[std.meta.fieldIndex(Target, name).?];
    }

    fn request(self: *Members, signature: *const Signature.Result, forwarded: []const Signature.Member, bindings: @FieldType(Shape, "bindings"), declaration: @FieldType(Shape, "callable"), facts: @FieldType(Shape, "signature")) Shape {
        self.storage.init();

        self.reads = .{ .target = &self.storage.buffer, .reads = &self.columns };

        return .{
            .target = &self.storage.view,
            .callable = declaration,
            .declared = !signature.type_only,
            .kinds = &kinds,
            .forwarded = std.mem.sliceAsBytes(forwarded),
            .bindings = bindings,
            .storage = @ptrCast(&self.storage.buffer),
            .buffer = @ptrCast(&self.storage.buffer.bytes),
            .reads = @ptrCast(&self.reads),
            .stride = @sizeOf(Signature.Member),
            .names = @ptrCast(self.column("name")),
            .signature = facts,
        };
    }
};

pub fn run(state: *project.Project, frame: *project.LoadFrame, unit: *project.Unit) zx.Error!void {
    const signature = &unit.signature.?;
    const allocator = state.allocator;
    const ir = zx.ir;
    var members: Members = undefined;
    var types: Rows(ir.Export, std.meta.Child(@FieldType(Exports, "types"))) = undefined;
    var constants: Rows(ir.Constant, std.meta.Child(@FieldType(Exports, "constants"))) = undefined;
    var scratch = std.heap.ArenaAllocator.init(state.arena.child_allocator);

    defer scratch.deinit();

    const temporary = scratch.allocator();
    var buckets: []u64 = &.{};
    const native = frame.export_functions.items;
    const bindings = FunctionImport.Readable.borrowRows(native);
    const BindingShape = std.meta.Child(@FieldType(Members.Shape, "bindings"));
    const Facts = std.meta.Child(@FieldType(BindingShape, "facts"));
    const MemberSource = std.meta.Child(@FieldType(Facts, "members"));
    const empty: []const FunctionImport = &.{};
    const no_ids = memory.borrowOptionalU32Column("id", empty);
    const names = memory.borrowTextColumn("name", native);
    const named = bindings.view(std.meta.Child(@FieldType(MemberSource, "named")));
    const source: MemberSource = .{ .named = &named, .fallback = null };
    const facts = Signature.bindingFacts(Facts, &source, state.functions.stores.items);

    const binding_rows: BindingShape = .{
        .names = @ptrCast(&names),
        .facts = &facts,
        .count = native.len,
    };

    const declaration: std.meta.Child(@FieldType(Members.Shape, "callable")) = .{
        .input_type = @backingInt(signature.ports.input_type),
        .output_type = @backingInt(signature.ports.output_type),
        .has_store = signature.has_store,
    };

    const selection: std.meta.Child(@FieldType(Members.Shape, "signature")) = .{
        .kinds = @ptrCast(members.column("kind")),
        .inputs = @ptrCast(members.column("input_type")),
        .outputs = @ptrCast(members.column("output_type")),
        .stores = @ptrCast(members.column("has_store")),
        .sources = @ptrCast(members.column("source")),
        .callable = @backingInt(Signature.Member.Kind.callable),
        .deferred = @backingInt(Signature.Member.Kind.deferred),
        .intrinsic = @backingInt(Signature.Member.Kind.intrinsic),
    };

    const target = members.request(signature, frame.signature_members.items, &binding_rows, &declaration, &selection);
    const type_rows = types.borrow(signature.exports, frame.export_aliases.items);
    const constant_rows = constants.borrow(signature.constant_exports, frame.export_constants.items);
    const exports: Exports = .{ .types = &type_rows, .constants = &constant_rows };

    const validation: std.meta.Child(@FieldType(Input, "validation")) = .{
        .scratch = @ptrCast(&temporary),
        .buckets = @ptrCast(&buckets),
        .no_ids = @ptrCast(&no_ids),
    };

    const input: Input = .{
        .members = &target,
        .exports = &exports,
        .validation = &validation,
    };

    const result = zx.columns.invoke(generated.executeValue, allocator, &input) catch |err|
        return @import("../invoke.zig").errorSet(err);

    const effective = result.signature;

    if (effective.duplicate) |name| return project.public_exports.reportDuplicate(allocator, state.reporter, name);
    if (effective.invalid) return state.reporter.fail(.module, .{ .start = 0, .end = 0 }, "a default re-export requires a callable source");

    signature.members = members.storage.rows();
    signature.exports = typedRows(ir.Export, result.exports);
    signature.constant_exports = typedRows(ir.Constant, result.constant_exports);
    signature.ports = .{ .input_type = @fromBackingInt(effective.input_type), .output_type = @fromBackingInt(effective.output_type) };
    signature.has_store = effective.has_store;
    signature.type_only = effective.type_only;
    signature.has_deferred_source = effective.deferred != null;
    signature.deferred_source = effective.deferred orelse &.{};

    publishBindings(unit, frame);
}

fn typedRows(comptime Row: type, bytes: []const u8) []const Row {
    if (bytes.len == 0) return &.{};

    return @alignCast(std.mem.bytesAsSlice(Row, bytes));
}

pub fn publishBindings(unit: *project.Unit, frame: *const project.LoadFrame) void {
    unit.signature_aliases = frame.aliases.items;
    unit.signature_imports = frame.imports.items;
    unit.signature_reexports = frame.export_functions.items;
    unit.signature_constant_imports = frame.constant_imports.items;
}
