const std = @import("std");
const ast = @import("ast.zig");
const diagnostic = @import("diagnostic.zig");

pub const Bounds = struct {
    min: usize = 0,
    max: usize = std.math.maxInt(usize),
};

pub const empty = sequence(.{});

pub fn list(comptime Child: type, comptime bounds: Bounds) type {
    return listWith(void, Child, bounds);
}

pub fn listWith(comptime Rules: type, comptime Child: type, comptime bounds: Bounds) type {
    if (bounds.min > bounds.max) @compileError("DSL list min exceeds max");

    return struct {
        pub const Data = []const Child.Data;

        pub fn decode(allocator: std.mem.Allocator, input: anytype, reporter: *diagnostic.Reporter, context: anytype) diagnostic.Error!Data {
            const node = ast.view(input);
            const count = node.childCount();

            try checkCount(Rules, node, count, bounds, reporter);

            const values = try allocator.alloc(Child.Data, count);
            var children = node.children();

            for (values) |*value| {
                value.* = try Child.decode(allocator, children.next().?, reporter, context);
            }

            return values;
        }
    };
}

pub fn sequence(comptime schemas: anytype) type {
    return sequenceWith(void, schemas);
}

pub fn sequenceWith(comptime Rules: type, comptime schemas: anytype) type {
    const types = blk: {
        var result: [schemas.len]type = undefined;

        for (schemas, 0..) |Schema, index| result[index] = Schema.Data;

        break :blk result;
    };

    return struct {
        pub const Data = @Tuple(&types);

        pub fn decode(allocator: std.mem.Allocator, input: anytype, reporter: *diagnostic.Reporter, context: anytype) diagnostic.Error!Data {
            const node = ast.view(input);

            try checkCount(Rules, node, node.childCount(), .{ .min = schemas.len, .max = schemas.len }, reporter);

            var values: Data = undefined;
            var children = node.children();

            inline for (schemas, 0..) |Schema, index| {
                values[index] = try Schema.decode(allocator, children.next().?, reporter, context);
            }

            return values;
        }
    };
}

pub fn choice(comptime schemas: anytype) type {
    return choiceWith(void, schemas);
}

pub fn choiceWith(comptime Rules: type, comptime schemas: anytype) type {
    const fields = @typeInfo(@TypeOf(schemas)).@"struct".field_names;

    if (fields.len == 0) @compileError("DSL choice requires at least one schema");

    const allowed_names = blk: {
        var names: []const []const u8 = &.{};

        for (fields) |field| {
            for (@field(schemas, field).names) |name| {
                for (names) |previous| {
                    if (std.mem.eql(u8, previous, name)) @compileError("Ambiguous DSL choice element: " ++ name);
                }

                names = names ++ .{name};
            }
        }

        break :blk names;
    };

    const owners = blk: {
        var result: [allowed_names.len]usize = undefined;
        var index: usize = 0;

        for (fields, 0..) |field, ordinal| {
            for (@field(schemas, field).names) |_| {
                result[index] = ordinal;
                index += 1;
            }
        }

        break :blk result;
    };

    const DataType = blk: {
        var types: [fields.len]type = undefined;

        for (fields, 0..) |field, index| {
            types[index] = @field(schemas, field).Data;
        }

        break :blk @Union(.auto, std.meta.FieldEnum(@TypeOf(schemas)), std.meta.fieldNames(@TypeOf(schemas)), &types, &@splat(.{}));
    };

    return struct {
        pub const Data = DataType;
        pub const names = allowed_names;

        pub fn matches(name: []const u8) bool {
            return select(name) != null;
        }
        fn select(name: []const u8) ?usize {
            if (comptime Rules != void) return if (Rules.select(name, names)) |index| owners[index] else null;

            inline for (fields, 0..) |field, index| {
                if (@field(schemas, field).matches(name)) return index;
            }

            return null;
        }
        pub fn decode(allocator: std.mem.Allocator, input: anytype, reporter: *diagnostic.Reporter, context: anytype) diagnostic.Error!Data {
            const node = ast.view(input);
            const selected = select(node.name());

            inline for (fields, 0..) |field, ordinal| {
                const Schema = @field(schemas, field);

                if (selected == ordinal) return @unionInit(Data, field, try Schema.decode(allocator, input, reporter, context));
            }

            return reporter.fail(.{
                .code = .unexpected_element,
                .location = node.location(),
                .element = node.name(),
                .message = "Element does not match any allowed alternative",
            });
        }
    };
}

fn checkCount(comptime Rules: type, node: anytype, count: usize, comptime bounds: Bounds, reporter: *diagnostic.Reporter) diagnostic.Error!void {
    if (count == bounds.min or (bounds.min == 0 and bounds.max == std.math.maxInt(usize))) return;

    const invalid = if (comptime Rules != void)
        Rules.childCount(count, bounds.min, bounds.max)

    else if (count < bounds.min)
        count
    else if (count > bounds.max)
        bounds.max
    else
        null;

    return reporter.fail(.{
        .code = .child_count,
        .location = if (invalid) |row| if (row < count) ast.view(ast.childAt(node, row)).location() else node.location() else return,
        .element = node.name(),
        .child_count = .{ .min = bounds.min, .max = bounds.max, .actual = count },
        .message = "Number of child elements does not match the schema",
    });
}
