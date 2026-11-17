const zx = @import("zx");
const memory = zx.memory;
const Initializer = @import("../../../compiled.zig").StoreInitializer;

pub fn View(comptime Target: type) type {
    return struct {
        identities: memory.TextColumn,
        versions: memory.ReadColumn,
        functions: memory.ReadColumn,
        input: Target,
        pub fn init(self: *@This(), rows: []const Initializer) void {
            self.identities = memory.borrowTextColumn("identity", rows);
            self.versions = memory.borrowReadColumn(u32, "schema_version", rows);
            self.functions = memory.borrowReadColumn(zx.ir.FunctionId, "function", rows);

            self.input = .{
                .count = rows.len,
                .identities = @ptrCast(&self.identities),
                .versions = @ptrCast(&self.versions),
                .functions = @ptrCast(&self.functions),
            };
        }
    };
}
