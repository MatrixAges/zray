const std = @import("std");
const ir = @import("zx").ir;
const Function = @import("function.zig");
const Level = @import("level.zig").Level;
const Growth = @import("growth.zig");
const Summaries = @import("summaries.zig");
const Hash = @import("zx").Sha256;
const Self = @This();
const generated_encoding = @import("genz_options").generated_analysis;
const Encoding = @import("memo/encoding.zig");
const Table = @import("memo/table.zig").Table;
/// Results of body analyses by the exact state they read: the body's identity, its own input summary, the output
/// summaries of its callees, and its growth copies. An analysis is a pure function of that state, so a body met again
/// in the same state replays what it passed on instead of being analyzed again; the replay meets the same
/// contributions in the same order, which keeps the worklist order and the result unchanged. Records persist across
/// builds by `save` and `load`, so an edit only analyzes the bodies whose state it changes.
pub const Settled = struct { passed: []const Function.Contribution, output: []const Level, used: bool = true };
/// A demand pass also reads the demands on its callees' inputs and its own output, and leaves its growth copies.
pub const Demanded = struct { marks: []const Function.Mark, normalized: []const Normalized, renewed: []const Renewed, grew: bool, used: bool = true };
pub const Normalized = Growth.Normalized;
pub const Renewed = Growth.Renewed;

/// The plan of a body once every fact settled.
pub const Planned = struct {
    flags: []const Function.Flags,
    renewals: Function.Renewals,
    transfers: []const u64 = &.{},
    slot_first: []const u32 = &.{},
    used: bool = true,
    pub fn fromPlan(value: Function.Plan) Planned {
        return .{ .flags = value.flags, .renewals = value.renewals, .transfers = value.transfers, .slot_first = value.slot_first };
    }
    pub fn plan(self: Planned) Function.Plan {
        return .{ .flags = self.flags, .renewals = self.renewals, .transfers = self.transfers, .slot_first = self.slot_first };
    }
};

/// Which input slots a body's output holds and its updates write, by the body and its callees' own.
pub const Flowed = struct { held: []const bool, text_held: []const bool, written: []const bool, used: bool = true };

/// What one body reads beyond the facts other bodies hand it.
pub const State = struct {
    identity: [32]u8,
    index: usize,
    input: []const Level,
    callees: []const u32,
    growth: *const Growth.Store,
};

pub const Digest = [32]u8;
const Trace = @import("trace.zig");

arena: std.heap.ArenaAllocator,
settled: Table(Settled) = .empty,
demanded: Table(Demanded) = .empty,
planned: Table(Planned) = .empty,
flowed: Table(Flowed) = .empty,
key: Digest = undefined,
order: if (generated_encoding) void else std.ArrayList(Record) = if (generated_encoding) {} else .empty,
/// The bytes the next key digests, gathered so they are hashed in one call.
encoded: std.ArrayList(u8) = .empty,
encoding: if (generated_encoding) Encoding else void,
/// Where the state ends in `encoded`, before the kind of record.
state_end: usize = 0,
/// Whether bodies carry content identities, as records that outlive this program need.
persistent: bool,
/// A later analysis in this process can replay the exact visit sequence. Disk records alone need no trace.
record_trace: bool,
/// Whether this run added records; `stale` reports whether it also left loaded ones unused.
changed: bool = false,
/// The visits of the last analysis, which the next analysis of the same program follows; it is not saved.
trace: ?Trace = null,
pub fn init(backing: std.mem.Allocator, persistent: bool) Self {
    return .{ .arena = .init(backing), .persistent = persistent, .record_trace = persistent, .encoding = if (generated_encoding) Encoding.init(backing) else {} };
}

pub fn deinit(self: *Self) void {
    if (self.trace) |*trace| trace.deinit();

    if (generated_encoding) {
        const owner = self.arena.child_allocator;

        self.encoding.deinit();
        inline for (.{ &self.settled, &self.demanded, &self.planned, &self.flowed }) |table| table.deinit(owner);
    }

    self.arena.deinit();

    self.* = undefined;
}

fn indexAllocator(self: *Self) std.mem.Allocator {
    return if (generated_encoding) self.arena.child_allocator else self.arena.allocator();
}

pub const Kind = enum { settled, demanded, planned };

pub fn Result(comptime kind: Kind) type {
    return switch (kind) {
        .settled => Settled,
        .demanded => Demanded,
        .planned => Planned,
    };
}

/// Looks up a trace state and sets the key for publishing a replacement.
pub fn findReplay(self: *Self, comptime kind: Kind, identity: *const Digest, state: []const u8) ?Result(kind) {
    self.key = if (generated_encoding)
        @import("memo/replay_key.zig").build(@backingInt(kind), identity, state)

    else seeded: {
        var hash = Hash.init(.{});

        hash.update(identity);
        hash.update(state);
        hash.update(@tagName(kind));

        break :seeded hash.finalResult();
    };

    return use(Result(kind), &@field(self, @tagName(kind)), self.key);
}

/// The state from the last ordinary lookup, without the body identity.
pub fn lastState(self: *const Self) []const u8 {
    const end = if (generated_encoding) self.encoding.stateEnd() else self.state_end;

    return self.encodedBytes()[@sizeOf(Digest)..end];
}

pub fn getSettled(self: *Self, summaries: *const Summaries, state: State) std.mem.Allocator.Error!?Settled {
    try self.keyed(.settled, summaries, state);

    return use(Settled, &self.settled, self.key);
}

/// Whether a record of `kind` covers `state`, without marking it used.
pub fn holds(self: *Self, comptime kind: Kind, summaries: *const Summaries, state: State) std.mem.Allocator.Error!bool {
    try self.keyed(kind, summaries, state);

    return @field(self, @tagName(kind)).contains(self.key);
}

/// Sets `key` to the digest of what a body of `kind` reads in `state`.
fn keyed(self: *Self, comptime kind: Kind, summaries: *const Summaries, state: State) std.mem.Allocator.Error!void {
    if (generated_encoding)
        try self.encoding.key(self.arena.allocator(), kind, summaries, &state)
    else
        try self.encodeSeed(kind, summaries, state);

    Hash.hash(self.encodedBytes(), &self.key, .{});
}

/// Records the analysis of the state `getSettled` digested into `key`.
pub fn putSettled(self: *Self, key: Digest, passed: []const Function.Contribution, output: []const Level) std.mem.Allocator.Error!Settled {
    const allocator = self.arena.allocator();

    if (generated_encoding) {
        const held = try @import("function/summary.zig").retain(allocator, passed, output);

        return self.putOwnedSettled(key, held.passed, held.output);
    }

    return self.putOwnedSettled(key, try Function.copyContributions(allocator, passed), try allocator.dupe(Level, output));
}

pub fn putOwnedSettled(self: *Self, key: Digest, passed: []const Function.Contribution, output: []const Level) std.mem.Allocator.Error!Settled {
    const value = Settled{ .passed = passed, .output = output };

    try self.settled.put(self.indexAllocator(), key, value);

    self.changed = true;

    return value;
}

pub fn getDemanded(self: *Self, summaries: *const Summaries, state: State) std.mem.Allocator.Error!?Demanded {
    try self.keyed(.demanded, summaries, state);

    return use(Demanded, &self.demanded, self.key);
}

/// Records the demand pass of the state `getDemanded` digested into `key`, with the growth copies it left.
pub fn putDemanded(self: *Self, key: Digest, marks: []const Function.Mark, records: *const Growth.Store, grew: bool) std.mem.Allocator.Error!Demanded {
    const allocator = self.arena.allocator();
    const retained = if (generated_encoding) try @import("retain.zig").marks(allocator, marks) else try allocator.dupe(Function.Mark, marks);

    return self.putOwnedDemanded(key, retained, records, grew);
}

pub fn putOwnedDemanded(self: *Self, key: Digest, marks: []const Function.Mark, records: *const Growth.Store, grew: bool) std.mem.Allocator.Error!Demanded {
    const allocator = self.arena.allocator();
    const growth = if (generated_encoding) records.* else try records.capture(allocator);

    const value = Demanded{
        .marks = marks,
        .normalized = growth.normalized,
        .renewed = growth.renewed,
        .grew = grew,
    };

    try self.demanded.put(self.indexAllocator(), key, value);

    self.changed = true;

    return value;
}

pub fn getPlanned(self: *Self, summaries: *const Summaries, state: State) std.mem.Allocator.Error!?Planned {
    try self.keyed(.planned, summaries, state);

    return use(Planned, &self.planned, self.key);
}

/// Records a plan whose slices already belong to this memo's arena.
pub fn putOwnedPlan(self: *Self, key: Digest, plan: Function.Plan) std.mem.Allocator.Error!Planned {
    const value = Planned.fromPlan(plan);

    try self.planned.put(self.indexAllocator(), key, value);

    self.changed = true;

    return value;
}

/// The flow of the body `key` names; it only reads, so the bodies of one layer look up at once.
pub fn getFlowed(self: *const Self, key: Digest) ?Flowed {
    return self.flowed.get(key);
}

/// Keeps the flow `getFlowed` found for a later run.
pub fn keepFlowed(self: *Self, key: Digest) void {
    if (generated_encoding) return self.flowed.keep(key);
    if (self.flowed.getPtr(key)) |entry| entry.used = true;
}

pub fn putFlowed(self: *Self, key: Digest, held: []const bool, text_held: []const bool, written: []const bool) std.mem.Allocator.Error!void {
    const allocator = self.arena.allocator();

    const value = if (generated_encoding)
        try @import("retain.zig").flow(allocator, held, text_held, written)
    else
        Flowed{ .held = try allocator.dupe(bool, held), .text_held = try allocator.dupe(bool, text_held), .written = try allocator.dupe(bool, written) };

    try self.flowed.put(self.indexAllocator(), key, value);

    self.changed = true;
}

fn use(comptime Value: type, map: *Table(Value), key: Digest) ?Value {
    if (generated_encoding) return map.use(key);

    const entry = map.getPtr(key) orelse return null;

    entry.used = true;

    return entry.*;
}

fn encodeSeed(self: *Self, comptime kind: Kind, summaries: *const Summaries, state: State) std.mem.Allocator.Error!void {
    self.encoded.clearRetainingCapacity();

    try self.encoded.appendSlice(self.arena.allocator(), &state.identity);
    try self.int(u32, @intCast(state.index));
    try self.levels(state.input);
    // The identity covers which functions the body calls and their signatures, so only their summaries follow.
    for (state.callees) |callee| try self.levels(summaries.output[callee]);
    try self.entries(ir.ExprId, &state.growth.normalized);
    try self.entries(u64, &state.growth.renewed);

    if (kind == .demanded) {
        for (state.callees) |callee| try self.levels(summaries.inputs[callee]);
        try self.levels(if (state.index < summaries.outputs.len) summaries.outputs[state.index] else &.{});
    }

    self.state_end = self.encoded.items.len;

    try self.encoded.appendSlice(self.arena.allocator(), @tagName(kind));
}

const Record = struct { key: u64, level: Level };

fn collect(comptime Key: type, map: *const std.AutoHashMap(Key, Level), rows: []Record) void {
    var values = map.iterator();

    for (rows) |*row| {
        const entry = values.next().?;

        row.* = .{ .key = entryKey(Key, entry.key_ptr.*), .level = entry.value_ptr.* };
    }
}

/// Map entries in key order, so equal contents encode equally whatever order they were added in.
fn entries(self: *Self, comptime Key: type, map: *const std.AutoHashMap(Key, Level)) std.mem.Allocator.Error!void {
    try self.order.resize(self.arena.allocator(), map.count());

    collect(Key, map, self.order.items);

    std.mem.sortUnstable(Record, self.order.items, {}, struct {
        fn less(_: void, left: Record, right: Record) bool {
            return left.key < right.key;
        }
    }.less);

    try self.int(u32, @intCast(self.order.items.len));

    for (self.order.items) |record| {
        try self.int(if (Key == u64) u64 else u32, @intCast(record.key));

        const byte: u8 = @as(u3, @bitCast(record.level));

        try self.encoded.append(self.arena.allocator(), byte);
    }
}

fn entryKey(comptime Key: type, key: Key) u64 {
    return if (Key == u64) key else @backingInt(key);
}

/// Two three-bit levels per byte; the count makes the final padding unambiguous.
fn levels(self: *Self, values: []const Level) std.mem.Allocator.Error!void {
    try self.int(u32, @intCast(values.len));

    const bytes = try self.encoded.addManyAsSlice(self.arena.allocator(), (values.len + 1) / 2);

    @memset(bytes, 0);

    for (values, 0..) |value, index| bytes[index / 2] |= @as(u8, @as(u3, @bitCast(value))) << @intCast(index % 2 * 4);
}

fn int(self: *Self, comptime T: type, value: T) std.mem.Allocator.Error!void {
    var bytes: [@sizeOf(T)]u8 = undefined;

    std.mem.writeInt(T, &bytes, value, .little);

    try self.encoded.appendSlice(self.arena.allocator(), &bytes);
}

fn encodedBytes(self: *const Self) []const u8 {
    return if (generated_encoding) self.encoding.bytes() else self.encoded.items;
}

/// Writes a state `lastState` returned for a lookup of `kind` back into the summaries and growth copies of body `index`,
/// so the body can be analyzed in it again; false when the bytes do not describe a state of this body.
pub fn restore(comptime kind: Kind, owner: std.mem.Allocator, state: []const u8, summaries: *Summaries, index: usize, callees: []const u32, growth: *Growth.Store) std.mem.Allocator.Error!bool {
    if (generated_encoding) return @import("memo/restore.zig").apply(owner, state, summaries, index, callees, kind == .demanded, growth);

    var reader: std.Io.Reader = .fixed(state);

    return restoreFrom(kind, &reader, summaries, index, callees, &growth.normalized, &growth.renewed) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => false,
    };
}

fn restoreFrom(comptime kind: Kind, reader: *std.Io.Reader, summaries: *Summaries, index: usize, callees: []const u32, normalized: *std.AutoHashMap(ir.ExprId, Level), renewed: *std.AutoHashMap(u64, Level)) !bool {
    if (try reader.takeInt(u32, .little) != index) return false;
    try readLevels(reader, if (index < summaries.input.len) summaries.input[index] else &.{});
    for (callees) |callee| try readLevels(reader, summaries.output[callee]);
    try readEntries(ir.ExprId, reader, normalized);
    try readEntries(u64, reader, renewed);

    if (kind == .demanded) {
        for (callees) |callee| try readLevels(reader, summaries.inputs[callee]);
        try readLevels(reader, if (index < summaries.outputs.len) summaries.outputs[index] else &.{});
    }

    return reader.seek == reader.end;
}

fn readLevels(reader: *std.Io.Reader, values: []Level) !void {
    if (try reader.takeInt(u32, .little) != values.len) return error.InvalidState;

    const bytes = try reader.take((values.len + 1) / 2);

    for (values, 0..) |*value, position| value.* = @bitCast(@as(u3, @truncate(bytes[position / 2] >> @intCast(position % 2 * 4))));
}

fn readEntries(comptime Key: type, reader: *std.Io.Reader, map: *std.AutoHashMap(Key, Level)) !void {
    map.clearRetainingCapacity();

    for (0..try reader.takeInt(u32, .little)) |_| {
        const key = try reader.takeInt(if (Key == u64) u64 else u32, .little);
        const level = try reader.takeByte();

        try map.put(if (Key == u64) key else @fromBackingInt(key), @bitCast(std.math.cast(u3, level) orelse return error.InvalidState));
    }
}

const magic = "zxc.uniqueness.memo.v18";

/// Whether `save` would differ from what was loaded.
pub fn stale(self: *const Self) bool {
    if (self.changed) return true;

    inline for (.{ &self.settled, &self.demanded, &self.planned, &self.flowed }) |map| {
        if (generated_encoding) {
            if (map.hasUnused()) return true;
        } else {
            var values = map.iterator();

            while (values.next()) |entry| if (!entry.value_ptr.used) return true;
        }
    }

    return false;
}

/// The records this run used or added, for `load` in a later run.
pub fn save(self: *const Self, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
    if (generated_encoding) return @import("memo/writing.zig").save(self, allocator);

    var out: std.Io.Writer.Allocating = .init(allocator);

    errdefer out.deinit();

    const writer = &out.writer;

    writer.writeAll(magic) catch return error.OutOfMemory;

    try writeMap(Settled, writer, &self.settled);
    try writeMap(Demanded, writer, &self.demanded);
    try writeMap(Planned, writer, &self.planned);
    try writeMap(Flowed, writer, &self.flowed);

    return out.toOwnedSlice();
}

/// Takes the records of an earlier `save`; malformed data leaves the memo as it was.
pub fn load(self: *Self, bytes: []const u8) std.mem.Allocator.Error!void {
    if (generated_encoding) return @import("memo/loading.zig").load(self, bytes);

    var reader: std.Io.Reader = .fixed(bytes);

    self.loadSeed(&reader) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            self.settled.clearRetainingCapacity();
            self.demanded.clearRetainingCapacity();
            self.planned.clearRetainingCapacity();
            self.flowed.clearRetainingCapacity();
        },
    };
}

fn loadSeed(self: *Self, reader: *std.Io.Reader) !void {
    const header = try reader.take(magic.len);

    if (!std.mem.eql(u8, header, magic)) return error.InvalidMemo;

    inline for (.{ "settled", "demanded", "planned", "flowed" }, .{ Settled, Demanded, Planned, Flowed }) |field, Value| {
        const count = try reader.takeInt(u32, .little);

        try self.readMap(Value, reader, &@field(self, field), count);
    }

    if (reader.seek != reader.end) return error.InvalidMemo;
}

fn writeMap(comptime Value: type, writer: *std.Io.Writer, map: *const std.AutoHashMapUnmanaged(Digest, Value)) std.mem.Allocator.Error!void {
    var count: u32 = 0;
    var values = map.iterator();

    while (values.next()) |entry| count += @intFromBool(entry.value_ptr.used);

    writeValue(writer, count) catch return error.OutOfMemory;

    values = map.iterator();

    while (values.next()) |entry| {
        if (!entry.value_ptr.used) continue;

        writer.writeAll(entry.key_ptr) catch return error.OutOfMemory;
        writeValue(writer, entry.value_ptr.*) catch return error.OutOfMemory;
    }
}

fn readMap(self: *Self, comptime Value: type, reader: *std.Io.Reader, map: *std.AutoHashMapUnmanaged(Digest, Value), count: u32) !void {
    const allocator = self.arena.allocator();

    try map.ensureUnusedCapacity(allocator, count);

    for (0..count) |_| {
        const key = (try reader.takeArray(32)).*;
        var value = try readValue(Value, allocator, reader);

        value.used = false;

        map.putAssumeCapacity(key, value);
    }
}

fn writeValue(writer: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    const T = @TypeOf(value);

    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (info.layout == .@"packed") return writeValue(writer, @as(info.backing_integer.?, @bitCast(value)));

            inline for (info.field_names) |field| try writeValue(writer, @field(value, field));
        },
        .pointer => {
            try writer.writeInt(u32, @intCast(value.len), .little);
            for (value) |item| try writeValue(writer, item);
        },
        .bool => try writer.writeByte(@intFromBool(value)),
        .int => |info| try writer.writeInt(Whole(info), value, .little),
        .@"enum" => try writeValue(writer, @backingInt(value)),
        else => @compileError("unsupported memo field"),
    }
}

/// The backing integer of a packed struct stored as one byte.
fn Byte(comptime T: type) ?type {
    const info = switch (@typeInfo(T)) {
        .@"struct" => |value| value,
        else => return null,
    };

    if (info.layout != .@"packed") return null;

    const backing = info.backing_integer.?;

    return if (@typeInfo(backing).int.bits <= 8 and @typeInfo(backing).int.signedness == .unsigned) backing else null;
}

/// The whole-byte integer a narrower one is stored as.
fn Whole(comptime info: std.builtin.Type.Int) type {
    return @Int(info.signedness, (info.bits + 7) / 8 * 8);
}

fn readValue(comptime T: type, allocator: std.mem.Allocator, reader: *std.Io.Reader) !T {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (info.layout == .@"packed") return @bitCast(try readValue(info.backing_integer.?, allocator, reader));

            var result: T = undefined;

            inline for (info.field_names) |field| @field(result, field) = try readValue(@FieldType(T, field), allocator, reader);

            return result;
        },
        .pointer => |info| {
            const count = try reader.takeInt(u32, .little);
            const values = try allocator.alloc(info.child, count);

            // Level and flag lists make up most of a memo; their elements are single bytes, read in one take.
            if (comptime Byte(info.child)) |Backing| {
                for (values, try reader.take(values.len)) |*item, byte| item.* = @bitCast(std.math.cast(Backing, byte) orelse return error.InvalidMemo);

                return values;
            }

            for (values) |*item| item.* = try readValue(info.child, allocator, reader);

            return values;
        },
        .bool => {
            const byte = try reader.takeByte();

            return switch (byte) {
                0 => false,
                1 => true,
                else => error.InvalidMemo,
            };
        },
        .int => |info| {
            const value = try reader.takeInt(Whole(info), .little);

            return std.math.cast(T, value) orelse error.InvalidMemo;
        },
        .@"enum" => return @fromBackingInt(try readValue(@typeInfo(T).@"enum".tag_type, allocator, reader)),
        else => @compileError("unsupported memo field"),
    }
}
