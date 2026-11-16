const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const generated = @import("generated_function_error_sources");
const Input = std.meta.Child(generated.Input);
const Context = std.meta.Child(@FieldType(Input, "context"));
const Tables = std.meta.Child(@FieldType(Context, "types"));
const Functions = std.meta.Child(@FieldType(Context, "functions"));

const Columns = struct {
    names: [][]const []const u8,
    unknown: []bool,
    callees: [][]const u32,
};

const Sources = struct {
    allocator: std.mem.Allocator,
    columns: Columns,
    arenas: []std.heap.ArenaAllocator,
    pub fn deinit(self: Sources) void {
        for (self.arenas) |*arena| arena.deinit();

        self.allocator.free(self.arenas);
        self.allocator.free(self.columns.callees);
        self.allocator.free(self.columns.unknown);
        self.allocator.free(self.columns.names);
    }
};

pub fn collect(allocator: std.mem.Allocator, types: ir.TypeTable, functions: ir.FunctionTable) std.mem.Allocator.Error!Sources {
    const count = functions.count();
    const names = try allocator.alloc([]const []const u8, count);

    errdefer allocator.free(names);

    const unknown = try allocator.alloc(bool, count);

    errdefer allocator.free(unknown);

    const callees = try allocator.alloc([]const u32, count);

    errdefer allocator.free(callees);

    const arenas = try allocator.alloc(std.heap.ArenaAllocator, @max(@min(zx.parallel.width(), count), 1));

    errdefer allocator.free(arenas);

    for (arenas) |*arena| arena.* = .init(std.heap.smp_allocator);

    errdefer for (arenas) |*arena| arena.deinit();

    const base = ir.TypeTable.borrow(std.meta.Child(@FieldType(Tables, "base")), types);
    const delta = ir.TypeTable.borrow(std.meta.Child(@FieldType(Tables, "delta")), .{});
    const tables: Tables = .{ .base = &base, .delta = &delta };
    const borrowed_functions = zx.columns.borrow(Functions, &functions);
    const context: Context = .{ .types = &tables, .functions = &borrowed_functions };
    const columns: Columns = .{ .names = names, .unknown = unknown, .callees = callees };
    var work = Visits{ .context = &context, .columns = columns, .arenas = arenas };

    zx.parallel.spread(Visits, &work, Visits.run, arenas.len);

    if (work.failed.load(.monotonic)) return error.OutOfMemory;

    return .{ .allocator = allocator, .columns = columns, .arenas = arenas };
}

const Visits = struct {
    context: *const Context,
    columns: Columns,
    arenas: []std.heap.ArenaAllocator,
    next: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),
    fn run(self: *@This(), participant: usize) void {
        var scratch = std.heap.ArenaAllocator.init(std.heap.smp_allocator);

        defer scratch.deinit();

        const lasting = self.arenas[participant].allocator();

        while (!self.failed.load(.monotonic)) {
            const index = self.next.fetchAdd(1, .monotonic);

            if (index >= self.columns.names.len) return;

            _ = scratch.reset(.retain_capacity);

            const input: Input = .{ .context = self.context, .index = index };

            const output = generated.executeIn(scratch.allocator(), &input) catch {
                self.failed.store(true, .monotonic);

                return;
            };

            self.columns.names[index] = lasting.dupe([]const u8, output.names) catch {
                self.failed.store(true, .monotonic);

                return;
            };

            self.columns.callees[index] = lasting.dupe(u32, output.callees) catch {
                self.failed.store(true, .monotonic);

                return;
            };

            self.columns.unknown[index] = output.unknown;
        }
    }
};
