const std = @import("std");
const frontend = @import("frontend");
const Member = frontend.project.FunctionImport;
const Nodes = frontend.ArtifactNodes;
const Error = frontend.project.artifact.Error;
const memory = @import("zx").memory;

const fields = .{
    .names = "name",
    .intrinsics = "intrinsic",
    .ids = "id",
    .inputs = "input_type",
    .outputs = "output_type",
};

pub fn View(comptime Input: type) type {
    const Publication = std.meta.Child(@FieldType(Input, "public_members"));
    const Source = std.meta.Child(@FieldType(Publication, "source"));
    const Records = std.meta.Child(@FieldType(Input, "records"));
    const Members = std.meta.Child(@FieldType(Input, "members"));
    const Mapping = std.meta.Child(@FieldType(Publication, "functions"));

    return struct {
        const Self = @This();

        paths: memory.TextColumn,
        direct: memory.ReadFields(fields),
        lists: memory.ListFields(fields),
        source: Source,
        members: Members,
        records: Records,
        mapping: Mapping,
        publication: Publication,
        input: Input,
        pub fn init(self: *Self, analysis: *const frontend.AnalysisResult, entry_path: []const u8, nodes: *const Nodes) void {
            self.direct = memory.borrowReadFields(fields, analysis.public_functions);
            self.lists = memory.borrowListFields(&.{ "reexports", "functions" }, fields, analysis.modules);
            self.source = self.direct.bind(Source);
            self.members = self.lists.bind(Members);
            self.paths = memory.borrowTextColumn("path", analysis.modules);
            const range = nodes.functions.range;
            self.mapping = .{ .kind = .Range, .dense = &.{}, .sparse = &.{}, .planned = &.{}, .first = range.first, .prefix = range.prefix, .count = range.count };
            self.records = .{ .paths = @ptrCast(&self.paths), .count = analysis.modules.len, .entry_path = entry_path };

            self.publication = .{
                .source = &self.source,
                .selection = null,
                .type_ids = @ptrCast(nodes.types.mapped),
                .functions = &self.mapping,
                .anonymous = .Keep,
            };

            self.input = .{
                .public_members = &self.publication,
                .records = &self.records,
                .members = &self.members,
            };
        }
    };
}

pub fn publish(allocator: std.mem.Allocator, rows: anytype) std.mem.Allocator.Error![]const Member {
    const result = try allocator.alloc(Member, rows.len);

    for (rows, result) |row, *slot| {
        slot.* = .{
            .name = row.name,
            .namespace = row.namespace,
            .id = if (row.id) |id| @fromBackingInt(id) else null,
            .input_type = if (row.input_type) |id| @fromBackingInt(id) else null,
            .output_type = if (row.output_type) |id| @fromBackingInt(id) else null,
            .intrinsic = if (row.intrinsic) |id| @fromBackingInt(id) else null,
        };
    }

    return result;
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
