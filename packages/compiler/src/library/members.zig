const std = @import("std");
const frontend = @import("frontend");
const Member = frontend.project.FunctionImport;
const Nodes = frontend.ArtifactNodes;
const Error = frontend.project.artifact.Error;
const memory = @import("zx").memory;
const Field = enum { name, intrinsic, id, input_type, output_type };

const column_names = std.enums.EnumArray(Field, []const u8).init(.{
    .name = "names",
    .intrinsic = "intrinsics",
    .id = "ids",
    .input_type = "inputs",
    .output_type = "outputs",
});

pub fn View(comptime Input: type) type {
    const Publication = std.meta.Child(@FieldType(Input, "public_members"));
    const Source = std.meta.Child(@FieldType(Publication, "source"));
    const Target = std.meta.Child(@FieldType(Publication, "target"));
    const Records = std.meta.Child(@FieldType(Input, "records"));
    const Members = std.meta.Child(@FieldType(Input, "members"));
    const Mapping = std.meta.Child(@FieldType(Publication, "functions"));

    return struct {
        const Self = @This();

        output: memory.RowOutput(Member, Target, .{
            .names = &.{"name"},
            .intrinsics = &.{"intrinsic"},
            .ids = &.{"id"},
            .inputs = &.{"input_type"},
            .outputs = &.{"output_type"},
            .namespaces = &.{"namespace"},
        }),
        paths: memory.TextColumn,
        direct: std.enums.EnumArray(Field, memory.ReadColumn),
        lists: std.enums.EnumArray(Field, memory.ListColumn),
        projected: std.enums.EnumArray(Field, memory.ReadColumn),
        source: Source,
        members: Members,
        records: Records,
        mapping: Mapping,
        projection: memory.ListProjection,
        publication: Publication,
        input: Input,
        pub fn init(self: *Self, analysis: *const frontend.AnalysisResult, entry_path: []const u8, nodes: *const Nodes) void {
            self.output.init();

            const public = analysis.public_functions;

            inline for (std.enums.values(Field)) |field| {
                const name = @tagName(field);
                const column = comptime column_names.get(field);

                const Scalar = switch (field) {
                    .name => []const u8,
                    .intrinsic => ?u8,
                    else => ?u32,
                };

                self.direct.set(field, switch (field) {
                    .name => memory.borrowTextColumn(name, public),
                    .intrinsic => memory.borrowOptionalU8Column(name, public),
                    else => memory.borrowOptionalU32Column(name, public),
                });

                self.lists.set(field, memory.borrowListPath(Scalar, &.{ "reexports", "functions" }, &.{name}, analysis.modules));
                @field(self.source, column) = @ptrCast(self.direct.getPtr(field));
                @field(self.members, column) = @ptrCast(self.projected.getPtr(field));
            }

            self.source.count = public.len;
            self.paths = memory.borrowTextColumn("path", analysis.modules);
            self.projection = .{ .sources = &self.lists.values, .target = &self.projected.values };
            const range = nodes.functions.range;
            self.mapping = .{ .kind = .Range, .dense = &.{}, .sparse = &.{}, .planned = &.{}, .first = range.first, .prefix = range.prefix, .count = range.count };
            self.records = .{ .paths = @ptrCast(&self.paths), .names = @ptrCast(self.lists.getPtr(.name)), .intrinsics = @ptrCast(self.lists.getPtr(.intrinsic)), .count = analysis.modules.len, .entry_path = entry_path };

            self.publication = .{
                .source = &self.source,
                .target = &self.output.view,
                .type_ids = @ptrCast(nodes.types.mapped),
                .functions = &self.mapping,
                .entry = null,
                .first = 0,
                .anonymous = .Keep,
            };

            self.input = .{
                .public_members = &self.publication,
                .records = &self.records,
                .storage = @ptrCast(&self.output.buffer),
                .members = &self.members,
                .projection = @ptrCast(&self.projection),
            };
        }
    };
}

pub fn completeSeed(owned: std.mem.Allocator, analysis: *const frontend.AnalysisResult, entry_path: []const u8, nodes: *Nodes) Error![]const Member {
    var result: std.ArrayList(Member) = .empty;

    try appendSeed(owned, &result, analysis.public_functions, false, nodes);

    for (analysis.modules) |record| {
        if (std.mem.eql(u8, record.path, entry_path)) try appendSeed(owned, &result, record.reexports.functions, true, nodes);
    }

    return result.items;
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
