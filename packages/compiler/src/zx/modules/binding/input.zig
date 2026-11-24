const std = @import("std");
const zx = @import("zx");
const Symbols = @import("symbols.zig").Symbols;
const delivery = @import("generated_project_binding_delivery");
const memory = @import("zx").memory;
pub const Input = @FieldType(std.meta.Child(delivery.Input), "request");
const Record = valueType(Input);
const Names = @FieldType(Record, "names");
const NativeNames = @typeInfo(field(Names, "native")).optional.child;
const Exports = @FieldType(Record, "exports");
const Constants = @FieldType(Record, "constants");
const Members = @FieldType(Record, "members");

pub const Storage = struct {
    input: Record,
    names: valueType(Names),
    exports: valueType(Exports),
    export_rows: []const memory.NamedId,
    constants: valueType(Constants),
    members: valueType(Members),
    signatures: valueType(Members),
    constant_names: memory.TextColumn,
    member_names: memory.TextColumn,
    signature_names: memory.TextColumn,
    native: valueType(NativeNames),
    native_locals: memory.TextColumn,
    native_originals: memory.TextColumn,
    native_starts: memory.ReadColumn,
    native_ends: memory.ReadColumn,
    pub fn init(self: *Storage, item: anytype, symbols: *const Symbols) Input {
        self.names = self.importNames(item);
        self.export_rows = memory.borrowNamedRows("type_id", symbols.exports);

        self.exports = record(Exports, .{
            .rows = @as(field(Exports, "rows"), @ptrCast(&self.export_rows)),
            .length = @as(u64, self.export_rows.len),
        });

        self.constant_names = memory.borrowTextColumn("name", symbols.constants);
        self.member_names = symbols.functions.column();

        self.constants = record(Constants, .{
            .rows = @as(field(Constants, "rows"), @ptrCast(&self.constant_names)),
            .length = @as(u64, self.constant_names.count),
            .default_name = @as(?[]const u8, null),
        });

        self.members = record(Members, .{
            .rows = @as(field(Members, "rows"), @ptrCast(&self.member_names)),
            .length = @as(u64, symbols.functions.count()),
            .default_name = symbols.functions.default,
        });

        if (symbols.signatures.len != 0) {
            self.signature_names = memory.borrowTextColumn("name", symbols.signatures);

            self.signatures = record(Members, .{
                .rows = @as(field(Members, "rows"), @ptrCast(&self.signature_names)),
                .length = @as(u64, self.signature_names.count),
                .default_name = @as(?[]const u8, null),
            });
        }

        self.input = record(Input, .{
            .target = @as(@FieldType(Record, "target"), switch (symbols.target) {
                .source => .Source,
                .compiled => .Compiled,
                .native => .Native,
            }),
            .kind = @as(@FieldType(Record, "kind"), switch (item.kind) {
                .function => .Function,
                .enumeration => .Enumeration,
                .type_only => .TypeOnly,
            }),
            .reexport = item.exported,
            .wildcard = item.wildcard,
            .start = @as(u64, item.span.start),
            .end = @as(u64, item.span.end),
            .names = reference(Names, &self.names),
            .type_kinds = symbols.types.kinds,
            .exports = reference(Exports, &self.exports),
            .constants = reference(Constants, &self.constants),
            .members = reference(Members, &self.members),
            .signatures = @as(?Members, if (symbols.signatures.len != 0) reference(Members, &self.signatures) else null),
        });

        return reference(Input, &self.input);
    }
    fn importNames(self: *Storage, item: anytype) valueType(Names) {
        if (comptime @hasField(@TypeOf(item.header), "storage")) {
            const storage = item.header.storage;
            const row = storage.imports[item.index];
            const first: usize = @intCast(row.first);
            const count: usize = @intCast(row.count);

            return record(Names, .{
                .source = item.header.source,
                .locals = zx.columns.slice(field(Names, "locals"), storage.import_names[first..][0..count]),
                .originals = zx.columns.slice(field(Names, "originals"), storage.import_sources[first..][0..count]),
                .native = @as(?NativeNames, null),
                .count = @as(u64, count),
            });
        }

        const declaration = &item.header.program.imports[item.index];
        const locals = declaration.names;
        const originals = if (declaration.source_names.len == 0) locals else declaration.source_names;

        self.native_locals = memory.borrowTextColumn("text", locals);
        self.native_originals = memory.borrowTextColumn("text", originals);
        self.native_starts = memory.borrowNestedColumn(usize, &.{ "span", "start" }, originals);
        self.native_ends = memory.borrowNestedColumn(usize, &.{ "span", "end" }, originals);

        self.native = record(NativeNames, .{
            .locals = @as(field(NativeNames, "locals"), @ptrCast(&self.native_locals)),
            .originals = @as(field(NativeNames, "originals"), @ptrCast(&self.native_originals)),
            .starts = @as(field(NativeNames, "starts"), @ptrCast(&self.native_starts)),
            .ends = @as(field(NativeNames, "ends"), @ptrCast(&self.native_ends)),
        });

        return record(Names, .{
            .source = @as([]const u8, ""),
            .locals = @as(field(Names, "locals"), &.{}),
            .originals = @as(field(Names, "originals"), &.{}),
            .native = @as(?NativeNames, reference(NativeNames, &self.native)),
            .count = @as(u64, locals.len),
        });
    }
};

fn valueType(comptime Target: type) type {
    return if (@typeInfo(Target) == .pointer) std.meta.Child(Target) else Target;
}

fn field(comptime Target: type, comptime name: []const u8) type {
    return @FieldType(valueType(Target), name);
}

fn reference(comptime Target: type, source: *const valueType(Target)) Target {
    return if (@typeInfo(Target) == .pointer) source else source.*;
}

fn record(comptime Target: type, fields: anytype) valueType(Target) {
    const Value = valueType(Target);
    var value: Value = undefined;

    inline for (@typeInfo(Value).@"struct".field_names) |name| {
        @field(value, name) = if (comptime std.mem.eql(u8, name, "zx_origin")) null else @field(fields, name);
    }

    return value;
}
