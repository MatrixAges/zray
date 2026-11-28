const std = @import("std");
pub const ScratchArena = @import("arena.zig");
pub const ArenaScope = @import("arena_scope.zig");
pub const AtomicRows = @import("atomic_rows.zig");
pub const atomicRowsCount = AtomicRows.count;
pub const atomicRowLength = AtomicRows.rowLength;
pub const loadAtomicCell = AtomicRows.load;
const column_set = @import("column_set.zig");
pub const ByteWriter = @import("byte_writer.zig");
pub const ColumnSet = column_set.ColumnSet;
pub const bindColumnSet = column_set.bind;
const column_length = @import("column_length.zig");
pub const ColumnLengths = column_length.Lengths;
pub const borrowColumnLengths = column_length.borrow;
pub const lengthSlotCount = column_length.count;
pub const readLengthSlot = column_length.read;
pub const advanceLengthSlot = column_length.advance;
pub const columnSetSlotCount = column_set.slotCount;
pub const columnSetFirstLength = column_set.firstLength;
pub const functionColumnGrowth = column_set.growth;
pub const nativeColumnGrowth = column_set.growth;
pub const reserveColumnCell = column_set.reserveCell;
pub const borrowFunctionRecord = column_set.borrowRecord;
pub const borrowFunctionBodyRecord = column_set.borrowRecord;
pub const borrowFunctionNativeRecord = column_set.borrowRecord;
pub const emptyFunctionNativeRecord = column_set.zeroRecord;
pub const functionRowLayout = column_set.rowLayout;
pub const functionBodyLayout = column_set.projectedLayout;
pub const functionNativeLayout = column_set.projectedLayout;
pub const writeColumnCell = column_set.writeCell;
pub const column_transfer = @import("column_transfer.zig");
pub const borrowTransferGroup = column_transfer.borrowGroup;
pub const transferColumnCount = column_transfer.countColumns;
pub const transferOwnsPayload = column_transfer.ownsPayload;
pub const transferOwnsTextItems = column_transfer.ownsTextItems;
pub const transferTextList = column_transfer.textList;
pub const writeTransferTextList = column_transfer.writeTextList;
pub const reserveTransferColumn = column_transfer.reserveOne;
pub const transferLayout = column_transfer.layout;
pub const transferColumn = column_transfer.borrowColumn;
pub const transferColumnStride = column_transfer.columnStride;
pub const transferColumnLength = column_transfer.columnLength;
pub const copyTransferRange = column_transfer.copyRange;
pub const copyTransferCell = column_transfer.copyCell;
pub const retainTransferItem = column_transfer.retainItem;
pub const releaseTransferItem = column_transfer.releaseItem;
pub const publishTransferColumn = column_transfer.publishOne;
pub const cloneTextList = column_transfer.cloneTextList;

pub inline fn freeOwnedText(resource: *const anyopaque, text: []const u8) void {
    column_set.borrowAllocator(resource).free(text);
}

pub inline fn requireAllocation(success: bool) std.mem.Allocator.Error!void {
    if (!success) return error.OutOfMemory;
}

const rows = @import("rows.zig");
pub const NamedId = rows.NamedId;
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
pub const readReferenceColumn = reference_rows.column;
pub const readReferenceByteRange = reference_rows.byteRange;
pub const selectReferenceRow = reference_rows.select;
pub const readNestedReferenceRows = reference_rows.nested;
pub const readReferenceRowBytes = reference_rows.bytes;
pub const readReferenceRowOptionalU32 = reference_rows.optionalU32;
pub const readReferenceRowText = reference_rows.text;
pub const readBorrowedRowText = reference_rows.borrowedText;
pub const readBorrowedRowOptionalText = reference_rows.borrowedOptionalText;
pub const sameBorrowedBytes = reference_rows.sameBorrowedBytes;
pub const readBorrowedRowReference = reference_rows.borrowedReference;
pub const readBorrowedRowList = reference_rows.borrowedList;
pub const borrowedByteOffset = reference_rows.borrowedOffset;
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
pub const ListProjection = rows.ListProjection;
pub const selectListColumn = rows.selectList;
pub const selectListText = selectScopedList;
pub const selectListValue = selectScopedList;
pub const selectProjectedList = rows.selectProjectedList;

pub inline fn selectScopedList(allocator: std.mem.Allocator, scratch: ?*const anyopaque, source: *const anyopaque, index: u64) error{ IndexOutOfBounds, OutOfMemory }!*const anyopaque {
    const views = if (scratch) |resource| column_set.borrowAllocator(resource) else allocator;

    return rows.selectList(views, source, index);
}

pub const requireColumnBounds = rows.requireColumnBounds;
pub const columnLength = rows.columnLength;
pub const readTextColumn = rows.readText;
pub const readOptionalTextColumn = rows.readOptionalText;
pub const readTextListColumn = rows.readTextList;
pub const readOptionalTextListColumn = rows.readOptionalTextList;
pub const readIndirectTextColumn = rows.readIndirectText;
pub const readColumnU8 = rows.readColumnU8;
pub const readColumnBool = rows.readColumnBool;
pub const readColumnOptionalBool = rows.readColumnOptionalBool;
pub const readColumnI32 = rows.readColumnI32;
pub const readColumnU16 = rows.readColumnU16;
pub const readColumnU32 = rows.readColumnU32;
pub const readColumnU64 = rows.readColumnU64;
pub const readColumnIndex = rows.readColumnIndex;
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
const column = @import("write_column.zig");
const field_columns = @import("field_columns.zig");
pub const borrowReadFields = field_columns.borrowRead;
pub const borrowListFields = field_columns.borrowLists;
pub const ReadFields = field_columns.ReadFields;
pub const ListFields = field_columns.ListFields;
pub const RowOutput = column.RowOutput;

pub inline fn rowCapacityLimit() u64 {
    return std.math.maxInt(usize);
}

const scalar_column = @import("scalar.zig");
pub const Scalar = scalar_column.Value;
pub const readScalarKind = scalar_column.readKind;
pub const readScalarMagnitude = scalar_column.readMagnitude;
pub const readScalarFloat = scalar_column.readFloat;
pub const readScalarBoolean = scalar_column.readBoolean;
pub const readScalarEnumeration = scalar_column.readEnumeration;
pub const readScalarText = scalar_column.readText;
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

pub const SourceSpan = struct {
    start: usize,
    end: usize,
};

pub inline fn readU64(target: *const anyopaque, index: u64) error{IndexOutOfBounds}!u64 {
    return read(u64, target, index);
}

pub const readU64View = readU64;

inline fn read(comptime T: type, target: *const anyopaque, index: u64) error{IndexOutOfBounds}!T {
    const buffer: *const []T = @ptrCast(@alignCast(target));

    if (index >= buffer.len) return error.IndexOutOfBounds;

    return buffer.*[@intCast(index)];
}
