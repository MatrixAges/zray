const std = @import("std");
const sha256 = @import("sha256.zig");
pub const sha256Into = sha256.into;
pub const sha256IntoRange = sha256.intoRange;
pub const sha256FramedInto = sha256.framedInto;
const buffer_owner = @import("buffer_owner.zig");
pub const createBoolBuffer = buffer_owner.bools;
pub const createU8Buffer = buffer_owner.bytes;
pub const ScratchArena = @import("arena.zig");
pub const ArenaScope = @import("arena_scope.zig");
pub const selectArena = ArenaScope.select;
pub const selectAllocator = ArenaScope.selectAllocator;
const stream = @import("stream.zig");
pub const takeByte = stream.takeByte;
pub const takeU32Le = stream.takeU32Le;
pub const takeU64Le = stream.takeU64Le;
pub const takeText = stream.takeText;
pub const writeStreamText = stream.writeText;
pub const writeStreamJsonBytes = stream.writeJsonBytes;
const atomic = @import("atomic.zig");
pub const loadU32Acquire = atomic.loadU32Acquire;
pub const storeU32Release = atomic.storeU32Release;
pub const compareExchangeU32Acquire = atomic.compareExchangeU32Acquire;
pub const exchangeU32Release = atomic.exchangeU32Release;
pub const waitU32 = atomic.waitU32;
pub const wakeOneU32 = atomic.wakeOneU32;
pub const loadU32Sequential = atomic.loadU32Sequential;
pub const loadU32Relaxed = atomic.loadU32Relaxed;
pub const storeU32Sequential = atomic.storeU32Sequential;
pub const storeU32Relaxed = atomic.storeU32Relaxed;
pub const compareExchangeU32Sequential = atomic.compareExchangeU32Sequential;
pub const addU32Sequential = atomic.addU32Sequential;
pub const wakeAllU32 = atomic.wakeAllU32;
pub const spinHint = atomic.spinHint;
const column_set = @import("column_set.zig");
pub const ByteWriter = @import("byte_writer.zig");
pub const appendByte = ByteWriter.appendByte;
pub const appendBytes = ByteWriter.appendBytes;
pub const appendText = ByteWriter.appendBytes;
pub const byteWriterLength = ByteWriter.length;
pub const borrowByteWriterBytes = ByteWriter.borrowBytes;
pub const clearByteWriter = ByteWriter.clear;
pub const reverseByteWriterTail = ByteWriter.reverseTail;
pub const ColumnSet = column_set.ColumnSet;
pub const ColumnLengths = column_set.Lengths;
pub const borrowColumnLengths = column_set.borrowLengths;
pub const publishColumnLengths = column_set.publishLengths;
pub const restoreColumnLengths = column_set.restoreLengths;
pub const captureColumnLengths = column_set.captureLengths;
pub const firstColumnLength = column_set.firstLength;
pub const truncateColumnLengths = column_set.truncateLengths;
pub const bindColumnSet = column_set.bind;
pub const ColumnRange = column_set.Range;
pub const ColumnRanges = column_set.Ranges;
pub const bindColumnRanges = column_set.bindRanges;
pub const publishTypeRanges = column_set.publishRanges;
pub const publishNominalRanges = column_set.publishRanges;
pub const setColumnRangeCount = column_set.setRangeCount;
pub const reserveColumnSet = column_set.reserve;
pub const readColumnSet = column_set.read;
pub const readFunctionColumns = column_set.read;
pub const readNativeColumnSet = column_set.read;
pub const readTypeColumns = column_set.read;
pub const readNominalColumns = column_set.read;
pub const appendColumnSet = column_set.append;
pub const appendFunctionBodyColumns = column_set.appendProjection;
pub const appendFunctionNativeColumns = column_set.appendProjection;
pub const appendSignatureColumnSet = column_set.append;
pub const writeFunctionTail = column_set.writeTail;
pub const writeSignatureTail = column_set.writeSignatureTail;
pub const reserveNativeColumnSet = column_set.reserve;
pub const appendNativeColumnSet = column_set.append;
pub const allocateColumnU32s = column_set.allocateU32s;
pub const writeColumnU32s = writeU32;
pub const copyColumnText = column_set.copyText;
pub const copyColumnBytes = column_set.copyText;
pub const copyColumnTextViews = column_set.copyTextViews;
pub const copyColumnTexts = column_set.copyTexts;
pub const copyColumnOptionalTexts = column_set.copyTexts;
pub const appendU64 = column_set.appendU64;
pub const column_transfer = @import("column_transfer.zig");
pub const reserveColumnGroup = column_transfer.reserve;
pub const columnGroupMatchesLength = column_transfer.matches;
pub const columnGroupMinimumLength = column_transfer.minimumLength;
pub const copyColumnGroup = column_transfer.copy;
pub const discardColumnGroup = column_transfer.discard;
pub const publishColumnGroup = column_transfer.publish;

pub inline fn reserveTypeRanges(resource: *const anyopaque, target: *const anyopaque, elements: anytype, limit: ?u64, precise: bool) std.mem.Allocator.Error!void {
    try column_set.reserveRanges(resource, target, elements, limit, precise, false);
}

pub inline fn reserveNominalRanges(resource: *const anyopaque, target: *const anyopaque, elements: anytype) std.mem.Allocator.Error!void {
    try column_set.reserveRanges(resource, target, elements, null, false, true);
}

pub fn resetArena(source: *const anyopaque) std.mem.Allocator.Error!void {
    if (!resetArenaRetainingCapacity(source)) return error.OutOfMemory;
}

pub fn resetArenaRetainingCapacity(source: *const anyopaque) bool {
    const arena: *std.heap.ArenaAllocator = @ptrCast(@alignCast(@constCast(source)));

    return arena.reset(.retain_capacity);
}

pub fn rewindScratchArena(source: *const anyopaque) void {
    const arena: *ScratchArena = @ptrCast(@alignCast(@constCast(source)));

    arena.rewindRetainingCapacity(.{ .chunk = null, .end = 0 });
}

pub inline fn stringViews(source: *const anyopaque) []const []const u8 {
    const view: *const []const []const u8 = @ptrCast(@alignCast(source));

    return view.*;
}

pub fn allocateStringViews(allocator: std.mem.Allocator, target: *const anyopaque, count: u64) std.mem.Allocator.Error!void {
    try allocateViews([]const u8, allocator, target, count);
}

pub fn allocateBoolViews(allocator: std.mem.Allocator, target: *const anyopaque, count: u64) std.mem.Allocator.Error!void {
    try allocateViews(bool, allocator, target, count);
}

pub fn allocateU32Views(allocator: std.mem.Allocator, target: *const anyopaque, count: u64) std.mem.Allocator.Error!void {
    try allocateViews(u32, allocator, target, count);
}

pub fn allocateU64Views(allocator: std.mem.Allocator, target: *const anyopaque, count: u64) std.mem.Allocator.Error!void {
    try allocateViews(u64, allocator, target, count);
}

fn allocateViews(comptime T: type, allocator: std.mem.Allocator, target: *const anyopaque, count: u64) std.mem.Allocator.Error!void {
    const output: *[]T = @ptrCast(@alignCast(@constCast(target)));
    output.* = try allocator.alloc(T, std.math.cast(usize, count) orelse return error.OutOfMemory);
}

pub inline fn u8Views(source: *const anyopaque) []const u8 {
    const view: *const []const u8 = @ptrCast(@alignCast(source));

    return view.*;
}

pub inline fn reserveU8Tail(resource: *const anyopaque, storage: *const anyopaque, source: *const anyopaque, tail: *const anyopaque, count: u64, limit: u64) std.mem.Allocator.Error!void {
    try column_set.reserveTail(u8, resource, storage, source, tail, count, limit);
}

pub inline fn reserveU32Tail(resource: *const anyopaque, storage: *const anyopaque, source: *const anyopaque, tail: *const anyopaque, count: u64, limit: u64) std.mem.Allocator.Error!void {
    try column_set.reserveTail(u32, resource, storage, source, tail, count, limit);
}

pub inline fn u32Views(source: *const anyopaque) []const u32 {
    const view: *const []const u32 = @ptrCast(@alignCast(source));

    return view.*;
}

pub inline fn optionalU32Views(source: *const anyopaque) []const ?u32 {
    const view: *const []const ?u32 = @ptrCast(@alignCast(source));

    return view.*;
}

pub inline fn refreshOptionalU32View(target: *const anyopaque, source: *const anyopaque) void {
    const view: *[]const ?u32 = @ptrCast(@alignCast(@constCast(target)));
    view.* = optionalU32Views(source);
}

pub inline fn borrowOptionalU32Range(source: []const ?u32, first: u64, count: u64) error{IndexOutOfBounds}![]const ?u32 {
    return borrowRange(?u32, source, first, count);
}

pub inline fn refreshLinkedPorts(source: *const anyopaque, target: *const anyopaque, shape: anytype) void {
    _ = column_set.read(source, target, shape);
}

const rows = @import("rows.zig");
pub const NamedId = rows.NamedId;
pub const NamedColumns = rows.NamedColumns;
pub const readNamedColumnName = rows.readNamedColumnName;
pub const readNamedColumnId = rows.readNamedColumnId;
pub const borrowNamedRows = rows.borrow;
pub const TextColumn = rows.TextColumn;
const references = @import("reference_column.zig");
pub const borrowReferenceColumn = references.borrow;
pub const readReferencedOptionalBytes = references.readOptionalBytes;
pub const readReferencedBytes = references.readBytes;
const reference_rows = @import("reference_rows.zig");
pub const ReferenceRows = reference_rows.Rows;
pub const borrowReferenceRows = reference_rows.borrow;
pub const referenceRowCount = reference_rows.count;
pub const sameReferenceRow = reference_rows.same;
pub const readReferenceRange = reference_rows.range;
pub const selectReferenceRow = reference_rows.select;
pub const readNestedReferenceRows = reference_rows.nested;
pub const readReferenceRowBytes = reference_rows.bytes;
pub const readReferenceRowOptionalU32 = reference_rows.optionalU32;
pub const readReferenceRowText = reference_rows.text;
pub const IndirectTextColumn = rows.IndirectTextColumn;
pub const ReadColumn = rows.ReadColumn;
pub const ListColumn = rows.ListColumn;
pub const borrowProjectedText = rows.borrowProjectedText;
pub const borrowTextColumn = rows.borrowText;
pub const borrowTextSlice = rows.borrowTextSlice;
pub const borrowIndirectTextColumn = rows.borrowIndirectText;
pub const borrowReadColumn = rows.borrowColumn;
pub const borrowNestedColumn = rows.borrowNested;
pub const columnFieldLayout = rows.fieldLayout;
pub const borrowOptionalU32Column = rows.borrowOptionalU32;
pub const borrowOptionalU8Column = rows.borrowOptionalU8;
pub const borrowListPath = rows.borrowListPath;
pub const borrowReferencedTextColumn = rows.borrowReferencedText;
pub const borrowReferencedTextPath = rows.borrowReferencedTextPath;
pub const borrowListColumn = rows.borrowList;
pub const borrowOptionalListColumn = rows.borrowOptionalList;
pub const borrowNestedListColumn = rows.borrowNestedList;
pub const borrowSliceColumn = rows.borrowSliceColumn;
pub const bindSliceColumns = rows.bindSliceColumns;
pub const readTypeSliceRow = rows.readSliceRow;
pub const readNominalSliceRow = rows.readSliceRow;
pub const ListProjection = rows.ListProjection;
pub const projectListColumns = rows.projectListColumns;
pub const columnLength = rows.columnLength;
pub const readTextColumn = rows.readText;
pub const readOptionalTextColumn = rows.readOptionalText;
pub const readTextListColumn = rows.readTextList;
pub const readOptionalTextListColumn = rows.readOptionalTextList;
pub const readIndirectTextColumn = rows.readIndirectText;
pub const readOptionalIndirectTextColumn = rows.readOptionalIndirectText;
pub const readColumnU8 = rows.readColumnU8;
pub const readColumnBool = rows.readColumnBool;
pub const readColumnOptionalBool = rows.readColumnOptionalBool;
pub const readColumnI32 = rows.readColumnI32;
pub const readColumnU16 = rows.readColumnU16;
pub const readColumnU32 = rows.readColumnU32;
pub const readColumnU64 = rows.readColumnU64;
pub const readColumnU32List = rows.readColumnU32List;
pub const readColumnU64List = rows.readColumnU64List;
pub const readColumnU32Lists = rows.readColumnU32Lists;
pub const readFixedBytes = rows.readFixedBytes;
pub const readOptionalU64List = rows.readOptionalU64List;
pub const readColumnOptionalU32 = rows.readColumnOptionalU32;
pub const readColumnOptionalU8 = rows.readColumnOptionalU8;
pub const listLength = rows.listLength;
pub const optionalListLength = rows.optionalListLength;
pub const readOptionalTextListItem = rows.readOptionalTextListItem;
pub const readListText = rows.readListText;
pub const readListOptionalText = rows.readListOptionalText;
pub const borrowListBytes = rows.borrowListBytes;
pub const readListBool = rows.readListBool;
pub const readListIndex = rows.readListIndex;
pub const readListU32 = rows.readListU32;
pub const readListU8 = rows.readListU8;
pub const readListU64 = rows.readListU64;
pub const readListOptionalU32 = rows.readListOptionalU32;
pub const readListOptionalU8 = rows.readListOptionalU8;
pub const readRowName = rows.readName;
pub const readRowId = rows.readId;
pub const writeNamedRow = rows.write;
pub const allocateNamedRows = rows.allocateNamedRows;
const column = @import("write_column.zig");
pub const WriteColumn = column.Column;
pub const RowBuffer = column.RowBuffer;
pub const refreshRowReads = column.refreshReads;
pub const RowOutput = column.RowOutput;
pub const RowGrowth = column.RowGrowth;
pub const growRows = column.growRows;
pub const reserveRows = column.reserveRows;
pub const rowBufferBytes = column.rowBufferBytes;
pub const allocateRows = column.allocateRows;
pub const allocateRowList = column.allocateRowList;
pub const writeRowList = column.writeRowList;
pub const moveRowList = column.moveRowList;
pub const writeNamedRowList = column.writeNamedRowList;
pub const copyRow = column.copyRow;
pub const writeRow = column.writeRow;
pub const writeRowByteView = column.writeRowByteView;
pub const writeRowByteField = column.writeRowByteField;

pub inline fn allocateRowsWithAllocator(resource: *const anyopaque, target: *const anyopaque, count: u64) std.mem.Allocator.Error!void {
    return column.allocateRows(column_set.borrowAllocator(resource), target, count);
}

pub const copyRowPrefix = column.copyRowPrefix;
pub const borrowWriteColumn = column.borrow;
pub const borrowNestedWriteColumn = column.borrowNested;
pub const writeColumnU8 = column.writeU8;
pub const writeColumnU32 = column.writeU32;
pub const writeColumnU64 = column.writeU64;
pub const writeColumnIndex = column.writeIndex;
pub const writeColumnBool = column.writeBool;
pub const writeColumnBytes = column.writeBytes;
pub const writeColumnU32List = column.writeU32List;
pub const writeColumnU64List = column.writeU64List;
pub const writeColumnU32Lists = column.writeU32Lists;
pub const writeColumnOptionalU32 = column.writeOptionalU32;
pub const writeColumnOptionalU8 = column.writeOptionalU8;
pub const writeColumnText = column.writeText;
pub const writeColumnOptionalText = column.writeOptionalText;
pub const writeColumnOptionalTextList = column.writeOptionalTextList;
pub const clearOptionalRowList = column.clearOptionalRowList;
pub const writeColumnTextList = column.writeTextList;
pub const writeColumnByteList = column.writeTextList;
pub const copyColumnValue = column.copyValue;
const scalar_column = @import("scalar.zig");
pub const Scalar = scalar_column.Value;
pub const readScalarKind = scalar_column.readKind;
pub const readScalarMagnitude = scalar_column.readMagnitude;
pub const readScalarFloat = scalar_column.readFloat;
pub const readScalarBoolean = scalar_column.readBoolean;
pub const readScalarEnumeration = scalar_column.readEnumeration;
pub const readScalarText = scalar_column.readText;
pub const copyScalar = scalar_column.copy;
pub const copyScalarAt = scalar_column.copyAt;
pub const writeScalarText = scalar_column.writeText;
pub const writeScalarInteger = scalar_column.writeInteger;
pub const writeScalarFloat = scalar_column.writeFloat;
pub const writeScalarBoolean = scalar_column.writeBoolean;
pub const writeScalarEnumeration = scalar_column.writeEnumeration;
pub const borrowTextRange = borrowU8Range;

pub inline fn borrowU8Range(source: []const u8, first: u64, count: u64) error{IndexOutOfBounds}![]const u8 {
    return borrowRange(u8, source, first, count);
}

pub inline fn readU64Bytes(source: []const u8, offset: u64, little_endian: bool) error{IndexOutOfBounds}!u64 {
    return readIntBytes(u64, source, offset, little_endian);
}

pub inline fn readI32Bytes(source: []const u8, offset: u64, little_endian: bool) error{IndexOutOfBounds}!i32 {
    return readIntBytes(i32, source, offset, little_endian);
}

pub inline fn i32Bits(value: i32) u32 {
    return @bitCast(value);
}

inline fn readIntBytes(comptime T: type, source: []const u8, offset: u64, little_endian: bool) error{IndexOutOfBounds}!T {
    const width = @sizeOf(T);

    if (offset > source.len or width > source.len - offset) return error.IndexOutOfBounds;

    return std.mem.readInt(T, source[@intCast(offset)..][0..width], if (little_endian) .little else .big);
}

pub inline fn borrowU32Range(source: []const u32, first: u64, count: u64) error{IndexOutOfBounds}![]const u32 {
    return borrowRange(u32, source, first, count);
}

pub inline fn borrowU64Range(source: []const u64, first: u64, count: u64) error{IndexOutOfBounds}![]const u64 {
    return borrowRange(u64, source, first, count);
}

pub inline fn borrowStringRange(source: []const []const u8, first: u64, count: u64) error{IndexOutOfBounds}![]const []const u8 {
    return borrowRange([]const u8, source, first, count);
}

inline fn borrowRange(comptime T: type, source: []const T, first: u64, count: u64) error{IndexOutOfBounds}![]const T {
    if (first > source.len or count > source.len - first) return error.IndexOutOfBounds;

    return source[@intCast(first)..][0..@intCast(count)];
}

pub inline fn copyBytes(target: *const anyopaque, offset: u64, source: []const u8, start: u64, end: u64) error{IndexOutOfBounds}!u64 {
    return copyRange(u8, target, offset, source, start, end);
}

pub inline fn copyU32Range(target: *const anyopaque, offset: u64, source: []const u32, start: u64, end: u64) error{IndexOutOfBounds}!void {
    _ = try copyRange(u32, target, offset, source, start, end);
}

inline fn copyRange(comptime T: type, target: *const anyopaque, offset: u64, source: []const T, start: u64, end: u64) error{IndexOutOfBounds}!u64 {
    const output: *const []T = @ptrCast(@alignCast(target));

    if (start > end or end > source.len or offset > output.len) return error.IndexOutOfBounds;

    const count = end - start;

    if (count > output.len - offset) return error.IndexOutOfBounds;

    @memmove(output.*[@intCast(offset)..][0..@intCast(count)], source[@intCast(start)..@intCast(end)]);

    return count;
}

pub inline fn copyU8s(target: *const anyopaque, source: []const u8) error{IndexOutOfBounds}!void {
    return copySlice(u8, target, source);
}

pub inline fn copyBools(target: *const anyopaque, source: []const bool) error{IndexOutOfBounds}!void {
    const buffer: *const []bool = @ptrCast(@alignCast(target));

    if (buffer.len != source.len) return error.IndexOutOfBounds;
    if (buffer.ptr == source.ptr) return;

    @memmove(buffer.*, source);
}

pub inline fn copyU32s(target: *const anyopaque, source: []const u32) error{IndexOutOfBounds}!void {
    return copySlice(u32, target, source);
}

pub inline fn copyU32sAt(target: *const anyopaque, offset: u64, source: []const u32) error{IndexOutOfBounds}!void {
    const buffer: *const []u32 = @ptrCast(@alignCast(target));

    if (offset > buffer.len or source.len > buffer.len - offset) return error.IndexOutOfBounds;

    @memmove(buffer.*[@intCast(offset)..][0..source.len], source);
}

pub inline fn copyStringViews(target: *const anyopaque, source: []const []const u8) error{IndexOutOfBounds}!void {
    return copySlice([]const u8, target, source);
}

pub inline fn copyText(allocator: std.mem.Allocator, value: []const u8) std.mem.Allocator.Error![]const u8 {
    return allocator.dupe(u8, value);
}

inline fn copySlice(comptime T: type, target: *const anyopaque, source: []const T) error{IndexOutOfBounds}!void {
    const buffer: *const []T = @ptrCast(@alignCast(target));

    if (buffer.len != source.len) return error.IndexOutOfBounds;

    @memmove(buffer.*, source);
}

pub inline fn writeUtf8Scalar(target: *const anyopaque, offset: u64, codepoint: u64) error{ IndexOutOfBounds, InvalidUnicodeScalar }!u64 {
    const output: *const []u8 = @ptrCast(@alignCast(target));
    const scalar = std.math.cast(u21, codepoint) orelse return error.InvalidUnicodeScalar;
    const count = std.unicode.utf8CodepointSequenceLength(scalar) catch return error.InvalidUnicodeScalar;

    if (offset > output.len or count > output.len - offset) return error.IndexOutOfBounds;

    return std.unicode.utf8Encode(scalar, output.*[@intCast(offset)..]) catch return error.InvalidUnicodeScalar;
}

pub inline fn writeU32(target: *const anyopaque, index: u64, value: u32) error{IndexOutOfBounds}!void {
    return write(u32, target, index, value);
}

pub inline fn u32BufferLength(source: *const anyopaque) u64 {
    const view: *const []u32 = @ptrCast(@alignCast(source));

    return view.len;
}

pub inline fn clearU32Buffer(target: *const anyopaque, count: u64) error{IndexOutOfBounds}!void {
    return fillU32Buffer(target, count, 0);
}

pub inline fn fillU32Buffer(target: *const anyopaque, count: u64, value: u32) error{IndexOutOfBounds}!void {
    const view: *const []u32 = @ptrCast(@alignCast(target));

    if (count > view.len) return error.IndexOutOfBounds;

    @memset(view.*[0..@intCast(count)], value);
}

pub const U32Scratch = struct {
    allocator: std.mem.Allocator,
    items: []u32 = &.{},
    backing: std.ArrayList(u32) = .empty,
    pub fn borrow(self: *U32Scratch, comptime View: type, precise: bool) View {
        return .{ .depths = @ptrCast(&self.items), .scratch = @ptrCast(self), .precise = precise };
    }

    pub fn deinit(self: *U32Scratch) void {
        self.backing.deinit(self.allocator);
    }
};

pub fn growU32Scratch(scratch: *const anyopaque, count: u64, precise: bool) std.mem.Allocator.Error!void {
    const workspace: *U32Scratch = @ptrCast(@alignCast(@constCast(scratch)));
    const length = std.math.cast(usize, count) orelse return error.OutOfMemory;

    if (precise) {
        try workspace.backing.ensureTotalCapacityPrecise(workspace.allocator, length);
    } else {
        try workspace.backing.ensureTotalCapacity(workspace.allocator, length);
    }

    workspace.items = workspace.backing.allocatedSlice();
}

pub fn allocateU32Buffer(resource: *const anyopaque, target: *const anyopaque, count: u64) std.mem.Allocator.Error!void {
    return allocateFilledU32Buffer(resource, target, count, 0);
}

pub fn allocateFilledU32Buffer(resource: *const anyopaque, target: *const anyopaque, count: u64, value: u32) std.mem.Allocator.Error!void {
    const allocator: *const std.mem.Allocator = @ptrCast(@alignCast(resource));
    const output: *[]u32 = @ptrCast(@alignCast(@constCast(target)));

    std.debug.assert(output.len == 0);

    const items = try allocator.alloc(u32, std.math.cast(usize, count) orelse return error.OutOfMemory);

    @memset(items, value);

    output.* = items;
}

pub inline fn writeU8(target: *const anyopaque, index: u64, value: u8) error{IndexOutOfBounds}!void {
    return write(u8, target, index, value);
}

pub inline fn writeBool(target: *const anyopaque, index: u64, value: bool) error{IndexOutOfBounds}!void {
    return write(bool, target, index, value);
}

pub inline fn boolViews(source: *const anyopaque) []const bool {
    const view: *const []bool = @ptrCast(@alignCast(source));

    return view.*;
}

pub inline fn fillByteRange(target: *const anyopaque, first: u64, count: u64, value: u8) error{IndexOutOfBounds}!void {
    const output: *const []u8 = @ptrCast(@alignCast(target));

    if (first > output.len or count > output.len - first) return error.IndexOutOfBounds;

    @memset(output.*[@intCast(first)..][0..@intCast(count)], value);
}

pub inline fn writeU64(target: *const anyopaque, index: u64, value: u64) error{IndexOutOfBounds}!void {
    return write(u64, target, index, value);
}

pub inline fn clearU64Buffer(target: *const anyopaque) void {
    const output: *const []u64 = @ptrCast(@alignCast(target));

    @memset(output.*, 0);
}

pub inline fn writeOptionalU32(target: *const anyopaque, index: u64, value: ?u32) error{IndexOutOfBounds}!void {
    return write(?u32, target, index, value);
}

pub fn allocateOptionalU32Buffer(allocator: std.mem.Allocator, target: *const anyopaque, count: u64, clear: bool) std.mem.Allocator.Error!void {
    const output: *[]?u32 = @ptrCast(@alignCast(@constCast(target)));
    const size = std.math.cast(usize, count) orelse return error.OutOfMemory;
    const items = try allocator.alloc(?u32, size);

    std.debug.assert(output.len == 0);

    if (clear) @memset(items, null);

    output.* = items;
}

pub inline fn allocateOptionalU32WithAllocator(resource: *const anyopaque, target: *const anyopaque, count: u64, clear: bool) std.mem.Allocator.Error!void {
    return allocateOptionalU32Buffer(column_set.borrowAllocator(resource), target, count, clear);
}

pub inline fn bindU32Range(source: *const anyopaque, target: *const anyopaque, first: u64, count: u64) error{IndexOutOfBounds}!void {
    const input: *const []u32 = @ptrCast(@alignCast(source));
    const output: *[]u32 = @ptrCast(@alignCast(@constCast(target)));

    if (first > input.len or count > input.len - first) return error.IndexOutOfBounds;

    output.* = input.*[@intCast(first)..][0..@intCast(count)];
}

pub inline fn writeString(target: *const anyopaque, index: u64, value: []const u8) error{IndexOutOfBounds}!void {
    return write([]const u8, target, index, value);
}

pub inline fn writeOptionalString(target: *const anyopaque, index: u64, value: ?[]const u8) error{IndexOutOfBounds}!void {
    return write(?[]const u8, target, index, value);
}

pub inline fn initializeU32ListSlot(target: *const anyopaque, index: u64, shape: anytype) error{IndexOutOfBounds}!std.meta.Child(@TypeOf(shape)) {
    const output: *const [][]const u32 = @ptrCast(@alignCast(target));

    if (index >= output.len) return error.IndexOutOfBounds;

    const slot = &output.*[@intCast(index)];

    slot.* = &.{};

    return @ptrCast(slot);
}

pub inline fn writeU8List(target: *const anyopaque, index: u64, value: []const u8) error{IndexOutOfBounds}!void {
    return write([]const u8, target, index, value);
}

pub inline fn writeU32List(target: *const anyopaque, index: u64, value: []const u32) error{IndexOutOfBounds}!void {
    return write([]const u32, target, index, value);
}

pub inline fn writeStringList(target: *const anyopaque, index: u64, value: []const []const u8) error{IndexOutOfBounds}!void {
    return write([]const []const u8, target, index, value);
}

/// Copies text into an exclusively borrowed destination and releases partial copies on failure.
pub fn copyStrings(allocator: std.mem.Allocator, target: *const anyopaque, source: []const []const u8) (std.mem.Allocator.Error || error{IndexOutOfBounds})!void {
    const output: *const [][]const u8 = @ptrCast(@alignCast(target));

    if (source.len != output.len) return error.IndexOutOfBounds;

    var copied: usize = 0;

    errdefer for (output.*[0..copied]) |text| allocator.free(text);

    for (source, output.*) |text, *item| {
        item.* = try allocator.dupe(u8, text);
        copied += 1;
    }
}

pub inline fn copyStringsWithAllocator(resource: *const anyopaque, target: *const anyopaque, source: []const []const u8) (std.mem.Allocator.Error || error{IndexOutOfBounds})!void {
    const allocator: *const std.mem.Allocator = @ptrCast(@alignCast(resource));

    try copyStrings(allocator.*, target, source);
}

// The caller exclusively lends a descriptor for a mutable slice for the duration of the call.
inline fn write(comptime T: type, target: *const anyopaque, index: u64, value: T) error{IndexOutOfBounds}!void {
    const buffer: *const []T = @ptrCast(@alignCast(target));

    if (index >= buffer.len) return error.IndexOutOfBounds;

    buffer.*[@intCast(index)] = value;
}

pub inline fn readU8(target: *const anyopaque, index: u64) error{IndexOutOfBounds}!u8 {
    return read(u8, target, index);
}

pub inline fn readU32(target: *const anyopaque, index: u64) error{IndexOutOfBounds}!u32 {
    return read(u32, target, index);
}

pub inline fn readU64(target: *const anyopaque, index: u64) error{IndexOutOfBounds}!u64 {
    return read(u64, target, index);
}

inline fn read(comptime T: type, target: *const anyopaque, index: u64) error{IndexOutOfBounds}!T {
    const buffer: *const []T = @ptrCast(@alignCast(target));

    if (index >= buffer.len) return error.IndexOutOfBounds;

    return buffer.*[@intCast(index)];
}
