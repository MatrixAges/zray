const std = @import("std");
const ir = @import("zx").ir;
const Basis = @import("basis.zig");
const Body = @import("program/bodies.zig").View;
const Hash = @import("zx").Sha256;
const Self = @This();

/// Content digests of what body analyses read besides the facts they exchange: the program shape every body shares
/// (types, function signatures, the basis) and each body itself. Source spans are left out, so moving code without
/// changing it keeps its digest.
hash: Hash = .init(.{}),
pub fn program(value: ir.Program, basis: *const Basis, return_allocations: []const bool) [32]u8 {
    if (@import("genz_options").generated_analysis) return @import("identity/program.zig").build(value, basis, return_allocations);

    var self = Self{};

    self.bytes("zxc.uniqueness.program.v21");
    self.bytes(&basis.types);
    self.write(value.functions.count());

    for (0..value.functions.count()) |index| {
        const function = value.functions.at(index);

        self.write(.{ .input_type = function.input_type, .output_type = function.output_type, .external = function.external != null });
    }

    self.write(basis.flow.held);
    self.write(basis.flow.written);
    self.write(basis.return_only);
    self.write(return_allocations);

    return self.finish();
}

/// The types every list slot derives from.
pub fn types(value: ir.TypeTable) [32]u8 {
    if (@import("genz_options").generated_analysis) return @import("identity/types.zig").build(value);

    var self = Self{};

    self.bytes("zxc.uniqueness.types.v1");
    self.write(value);

    return self.finish();
}

/// A body by itself, apart from the program it sits in.
fn content(symbols: *const ir.SymbolTable, expressions: *const ir.ExpressionTable, block: ir.Block, input_type: ir.TypeId, output_type: ir.TypeId) [32]u8 {
    if (@import("genz_options").generated_analysis) return @import("identity/content.zig").build(symbols, expressions, block, input_type, output_type);

    var self = Self{};

    self.write(.{ .symbols = symbols.*, .expressions = expressions.*, .block = block, .input_type = input_type, .output_type = output_type });

    return self.finish();
}

const Hashing = struct {
    program: *const ir.Program,
    mode: Mode,
    result: [][32]u8,
    next: std.atomic.Value(usize) = .init(0),
    const Mode = union(enum) {
        contents,
        memo: MemoRows,
    };

    const MemoRows = struct {
        active: []const bool,
        shared: *const [32]u8,
        known: []const [32]u8,
    };
    fn collect(allocator: std.mem.Allocator, program_view: *const ir.Program, mode: Mode, count: usize) std.mem.Allocator.Error![]const [32]u8 {
        var work: Hashing = .{ .program = program_view, .mode = mode, .result = try allocator.alloc([32]u8, count) };

        @import("zx").parallel.spread(Hashing, &work, run, count);

        return work.result;
    }
    fn run(self: *Hashing, _: usize) void {
        switch (self.mode) {
            .contents => self.fill(true),
            .memo => self.fill(false),
        }
    }

    fn fill(self: *Hashing, comptime only_contents: bool) void {
        while (self.claim()) |row| {
            self.result[row] = if (only_contents)
                if (self.program.functions.native_modules[row] != null) @splat(0) else hashBody(self.program, row)

            else if (!self.mode.memo.active[row])
                @splat(0)
            else if (row < self.mode.memo.known.len)
                combine(self.mode.memo.shared, &self.mode.memo.known[row])
            else
                self.hashAndCombine(row);
        }
    }
    fn claim(self: *Hashing) ?usize {
        const row = self.next.fetchAdd(1, .monotonic);

        return if (row < self.result.len) row else null;
    }
    fn hashAndCombine(self: *const Hashing, row: usize) [32]u8 {
        const content_digest = hashBody(self.program, row);

        return combine(self.mode.memo.shared, &content_digest);
    }
};

/// External functions have no body fingerprint.
pub fn contents(allocator: std.mem.Allocator, value: *const ir.Program) std.mem.Allocator.Error![]const [32]u8 {
    return Hashing.collect(allocator, value, .contents, value.functions.count());
}

pub fn bodies(allocator: std.mem.Allocator, program_view: *const ir.Program, active: []const bool, shared: *const [32]u8, known: []const [32]u8) std.mem.Allocator.Error![]const [32]u8 {
    return Hashing.collect(allocator, program_view, .{ .memo = .{ .active = active, .shared = shared, .known = known } }, active.len);
}

fn hashBody(program_view: *const ir.Program, index: usize) [32]u8 {
    const body = Body.at(program_view, index);

    return content(body.symbols, body.expressions, body.control.block(), body.input_type, body.output_type);
}

/// Combines the program digest with a body digest or the raw exported function IDs.
pub fn combine(shared: *const [32]u8, suffix: []const u8) [32]u8 {
    var hash: Hash = undefined;

    if (@import("genz_options").generated_analysis) {
        const zx = @import("zx");
        const entry = @import("generated_uniqueness_identity_combine");
        const Input = std.meta.Child(entry.Input);
        const storage = zx.Sha256State{ .value = &hash };
        const input: Input = .{ .hash = @ptrCast(&storage), .shared = shared, .suffix = suffix };
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        zx.columns.invoke(entry.executeValue, empty.allocator(), &input) catch unreachable;
    } else {
        hash = .init(.{});

        hash.update(shared);
        hash.update(suffix);
    }

    return hash.finalResult();
}

fn finish(self: *Self) [32]u8 {
    var result: [32]u8 = undefined;

    self.hash.final(&result);

    return result;
}

fn write(self: *Self, value: anytype) void {
    const T = @TypeOf(value);

    if (T == @FieldType(ir.ExpressionRow, "span")) return;
    if (T == ir.ControlBody) return self.write(value.block());

    if (T == ir.Block or T == @FieldType(ir.StatementRow, "parallel") or T == @FieldType(@FieldType(ir.StatementRow, "destructure"), "symbols") or T == @FieldType(@FieldType(ir.StatementRow, "switch_stmt"), "cases")) {
        self.write(value.len);

        for (0..value.len) |index| self.write(value.at(index));

        return;
    }

    if (T == ir.ExpressionTable or T == ir.SymbolTable or T == ir.TypeTable) {
        self.write(value.count());

        for (0..value.count()) |index| self.write(value.at(index));

        return;
    }

    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.field_names) |field| self.write(@field(value, field)),
        .@"union" => switch (value) {
            inline else => |payload, tag| {
                self.bytes(@tagName(tag));
                self.write(payload);
            },
        },
        .@"enum" => self.write(@backingInt(value)),
        .optional => {
            self.write(value != null);

            if (value) |child| self.write(child);
        },
        .pointer => |info| {
            if (info.size != .slice) @compileError("uniqueness identities require value data");
            if (info.child == u8) return self.bytes(value);

            self.write(value.len);

            for (value) |item| self.write(item);
        },
        .bool => self.hash.update(&.{@intFromBool(value)}),
        .int => {
            var encoded: [8]u8 = undefined;

            std.mem.writeInt(u64, &encoded, @as(u64, @truncate(@as(u128, @bitCast(@as(i128, value))))), .little);
            self.hash.update(&encoded);
        },
        .float => self.write(@as(@Int(.unsigned, @bitSizeOf(T)), @bitCast(value))),
        .void => {},
        else => @compileError("unsupported uniqueness identity field"),
    }
}

fn bytes(self: *Self, value: []const u8) void {
    self.write(value.len);
    self.hash.update(value);
}
