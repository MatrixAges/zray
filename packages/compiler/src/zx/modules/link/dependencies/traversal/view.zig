const memory = @import("zx").memory;
const Record = @import("../../../module_record.zig");
const Target = Record.Target.Kind;
const Import = @FieldType(Record.Import, "kind");

pub const Columns = struct {
    targets: []const u64,
    target_kinds: memory.ReadColumn,
    kinds: memory.ReadColumn,
    pub fn borrow(source: []const Record.Import, targets: []const u64) Columns {
        return .{
            .targets = targets,
            .target_kinds = memory.borrowNestedColumn(Target, &.{ "target", "kind" }, source),
            .kinds = memory.borrowReadColumn(Import, "kind", source),
        };
    }

    pub fn view(self: *const Columns, comptime Edges: type) Edges {
        return .{
            .targets = self.targets,
            .target_kinds = @ptrCast(&self.target_kinds),
            .kinds = @ptrCast(&self.kinds),
            .count = self.kinds.count,
            .codes = &.{
                .source = @backingInt(Target.source),
                .intrinsic = @backingInt(Target.intrinsic),
                .type_only = @backingInt(Import.type_only),
                .function = @backingInt(Import.function),
                .enumeration = @backingInt(Import.enumeration),
            },
        };
    }
};
