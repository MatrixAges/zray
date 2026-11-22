const std = @import("std");
const zx = @import("zx");
const Symbols = @import("symbols.zig").Symbols;
const generated = @import("generated_project_binding");
const memory = @import("zx").memory;
pub const Input = @typeInfo(@TypeOf(generated.executeValue)).@"fn".param_types[1].?;
const Record = valueType(Input);
const Names = @FieldType(Record, "names");
const Exports = @FieldType(Record, "exports");
const Constants = @FieldType(Record, "constants");
const Members = @FieldType(Record, "members");

pub const Storage = struct {
    input: Record,
    names: valueType(Names),
    exports: valueType(Exports),
    constants: valueType(Constants),
    members: valueType(Members),
    signatures: valueType(Members),
    constant_names: memory.TextColumn,
    member_names: memory.TextColumn,
    signature_names: memory.TextColumn,
    pub fn init(self: *Storage, allocator: std.mem.Allocator, item: anytype, symbols: *const Symbols, rows: *const []const memory.NamedId) std.mem.Allocator.Error!Input {
        self.names = try importNames(allocator, item);

        self.exports = record(Exports, .{
            .rows = @as(field(Exports, "rows"), @ptrCast(rows)),
            .length = @as(u64, rows.len),
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
};

fn importNames(allocator: std.mem.Allocator, item: anytype) std.mem.Allocator.Error!valueType(Names) {
    if (comptime @hasField(@TypeOf(item.header), "storage")) {
        const storage = item.header.storage;
        const row = storage.imports[item.index];
        const first: usize = @intCast(row.first);
        const count: usize = @intCast(row.count);

        return record(Names, .{
            .source = @as(?[]const u8, item.header.source),
            .locals = zx.columns.slice(field(Names, "locals"), storage.import_names[first..][0..count]),
            .originals = zx.columns.slice(field(Names, "originals"), storage.import_sources[first..][0..count]),
            .values = @as([]const []const u8, &.{}),
            .aliases = @as([]const []const u8, &.{}),
        });
    }

    const count = item.nameCount();
    const values = try allocator.alloc([]const u8, count);
    const aliases = try allocator.alloc([]const u8, count);
    const Span = std.meta.Child(field(Names, "originals"));
    const indirect = @typeInfo(Span) == .pointer;
    const Position = if (indirect) std.meta.Child(Span) else Span;
    const positions = try allocator.alloc(Position, count);
    const spans = if (indirect) try allocator.alloc(Span, count) else positions;

    for (values, aliases, positions, 0..) |*value, *alias, *span, index| {
        const source = item.sourceAt(index);

        value.* = source.text;
        alias.* = item.nameAt(index).text;
        span.* = .{ .start = source.span.start, .end = source.span.end };

        if (indirect) spans[index] = span;
    }

    return record(Names, .{
        .source = @as(?[]const u8, null),
        .locals = @as(field(Names, "locals"), &.{}),
        .originals = @as(field(Names, "originals"), spans),
        .values = @as([]const []const u8, values),
        .aliases = @as([]const []const u8, aliases),
    });
}

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
