const std = @import("std");
const frontend = @import("frontend");
const columns = @import("zx").columns;
const Member = frontend.project.FunctionImport;
const Nodes = frontend.ArtifactNodes;
const Error = frontend.project.artifact.Error;
const generated = @import("parser_options").generated_parser;
const memory = @import("zx").memory;
const Field = enum { name, intrinsic, id, input_type, output_type };

const column_names = std.enums.EnumArray(Field, []const u8).init(.{
    .name = "names", .intrinsic = "intrinsics", .id = "ids", .input_type = "inputs", .output_type = "outputs",
});

pub fn complete(owned: std.mem.Allocator, analysis: *const frontend.AnalysisResult, entry_path: []const u8, nodes: *Nodes) Error![]const Member {
    if (!generated) {
        var result: std.ArrayList(Member) = .empty;

        try appendSeed(owned, &result, analysis.public_functions, false, nodes);

        for (analysis.modules) |record| {
            if (std.mem.eql(u8, record.path, entry_path)) try appendSeed(owned, &result, record.reexports.functions, true, nodes);
        }

        return result.items;
    }

    const rule = @import("generated_library_public_members");
    const Input = std.meta.Child(rule.Input);
    const Publication = std.meta.Child(@FieldType(Input, "public_members"));
    const Source = std.meta.Child(@FieldType(Publication, "source"));
    const Target = std.meta.Child(@FieldType(Publication, "target"));

    var output: memory.RowOutput(Member, Target, .{
        .names = &.{"name"}, .intrinsics = &.{"intrinsic"}, .ids = &.{"id"},
        .inputs = &.{"input_type"}, .outputs = &.{"output_type"}, .namespaces = &.{"namespace"},
    }) = undefined;

    output.init();

    const public = analysis.public_functions;
    var direct: std.enums.EnumArray(Field, memory.ReadColumn) = undefined;
    var lists: std.enums.EnumArray(Field, memory.ListColumn) = undefined;
    var projected: std.enums.EnumArray(Field, memory.ReadColumn) = undefined;
    var source: Source = undefined;
    var members: std.meta.Child(@FieldType(Input, "members")) = undefined;

    inline for (std.enums.values(Field)) |field| {
        const name = @tagName(field);
        const column = comptime column_names.get(field);
        const Scalar = switch (field) { .name => []const u8, .intrinsic => ?u8, else => ?u32 };

        direct.set(field, switch (field) {
            .name => memory.borrowTextColumn(name, public),
            .intrinsic => memory.borrowOptionalU8Column(name, public),
            else => memory.borrowOptionalU32Column(name, public),
        });

        lists.set(field, memory.borrowListPath(Scalar, &.{ "reexports", "functions" }, &.{name}, analysis.modules));
        @field(source, column) = @ptrCast(direct.getPtr(field));
        @field(members, column) = @ptrCast(projected.getPtr(field));
    }

    source.count = public.len;

    const paths = memory.borrowTextColumn("path", analysis.modules);
    const projection: memory.ListProjection = .{ .sources = &lists.values, .target = &projected.values };
    const range = nodes.functions.range;

    const input: Input = .{
        .public_members = &.{
            .source = &source,
            .target = &output.view,
            .type_ids = @ptrCast(nodes.types.mapped),
            .functions = &.{ .kind = .Range, .dense = &.{}, .sparse = &.{}, .planned = &.{}, .first = range.first, .prefix = range.prefix, .count = range.count },
            .entry = null,
            .first = 0,
            .anonymous = .Keep,
        },
        .records = &.{ .paths = @ptrCast(&paths), .names = @ptrCast(lists.getPtr(.name)), .intrinsics = @ptrCast(lists.getPtr(.intrinsic)), .count = analysis.modules.len, .entry_path = entry_path },
        .storage = @ptrCast(&output.buffer),
        .members = &members,
        .projection = @ptrCast(&projection),
    };

    const valid = columns.invoke(rule.executeValue, owned, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    return if (valid) output.rows() else error.InvalidModule;
}

fn appendSeed(owned: std.mem.Allocator, result: *std.ArrayList(Member), source: []const Member, barrel: bool, nodes: *Nodes) Error!void {
    for (source) |item| {
        if (barrel and item.name.len == 0 and item.intrinsic == null) continue;

        var member = item;
        member.namespace = null;
        member.name = try owned.dupe(u8, item.name);
        member.id = if (item.id) |id| try nodes.functionId(id) else null;
        member.input_type = if (item.input_type) |id| try nodes.types.include(id) else null;
        member.output_type = if (item.output_type) |id| try nodes.types.include(id) else null;

        try result.append(owned, member);
    }
}
