const std = @import("std");
pub const ScratchArena = @import("arena.zig");
pub const ArenaScope = @import("arena_scope.zig");
const stream = @import("stream.zig");
pub const takeByte = stream.takeByte;
pub const takeU32Le = stream.takeU32Le;
pub const takeU64Le = stream.takeU64Le;
pub const takeText = stream.takeText;
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
pub const borrowSliceLengths = column_length.borrowSlices;
pub const borrowFunctionBodyBytes = std.mem.asBytes;
pub const borrowForwardedBodyBytes = std.mem.asBytes;
pub const lengthSlotCount = column_length.count;
pub const readLengthSlot = column_length.read;
pub const advanceLengthSlot = column_length.advance;
pub const shrinkLengthSlot = column_length.shrink;
const column_range = @import("column_range.zig");
pub const ColumnRanges = column_range.Ranges;
pub const bindColumnRanges = column_range.bind;
pub const ColumnRangeGroup = column_range.Group;
pub const columnRangeSlotCount = column_range.columns;
pub const columnRangeLength = column_range.length;
pub const columnRangeCount = column_range.count;
pub const reserveColumnRange = column_range.reserveOne;
pub const columnSetSlotCount = column_set.slotCount;
pub const columnSetFirstLength = column_set.firstLength;
pub const functionColumnGrowth = column_set.growth;
pub const nativeColumnGrowth = column_set.growth;
pub const reserveColumnCell = column_set.reserveCell;
pub const typeColumnLayout = column_set.viewLayout;
pub const nominalColumnLayout = column_set.viewLayout;
pub const moduleColumnLayout = column_set.viewLayout;
pub const signatureColumnLayout = column_set.viewLayout;
pub const linkedPortLayout = column_set.viewLayout;
pub const functionColumnLayout = column_set.viewLayout;
pub const readColumnCell = column_set.readCell;
pub const typeColumnView = column_set.viewAt;
pub const nominalColumnView = column_set.viewAt;
pub const moduleColumnView = column_set.viewAt;
pub const signatureColumnView = column_set.viewAt;
pub const functionColumnView = column_set.viewAt;
pub const borrowFunctionRecord = column_set.borrowRecord;
pub const borrowSignatureRecord = column_set.borrowRecord;
pub const borrowNativeModuleRecord = column_set.borrowRecord;
pub const borrowFunctionBodyRecord = column_set.borrowRecord;
pub const borrowFunctionNativeRecord = column_set.borrowRecord;
pub const emptyFunctionNativeRecord = column_set.zeroRecord;
pub const functionRowLayout = column_set.rowLayout;
pub const signatureRowLayout = column_set.rowLayout;
pub const nativeModuleRowLayout = column_set.rowLayout;
pub const functionBodyLayout = column_set.projectedLayout;
pub const functionNativeLayout = column_set.projectedLayout;
pub const rowCellCount = column_set.rowCellCount;
pub const writeColumnCell = column_set.writeCell;
pub const column_transfer = @import("column_transfer.zig");
pub const borrowTransferGroup = column_transfer.borrowGroup;
pub const transferColumnCount = column_transfer.countColumns;
pub const transferSourceLength = column_transfer.sourceLength;
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
const text_storage = @import("text_storage.zig");
pub const duplicateText = text_storage.duplicate;
pub const freeOwnedText = text_storage.free;
pub const freeTextSlots = text_storage.free;
pub const freeOptionalTextSlots = text_storage.free;
pub const requireTextSlots = text_storage.require;
pub const requireOptionalTextSlots = text_storage.require;
pub const checkTextSlotCount = text_storage.checkLength;

pub inline fn allocateTextSlots(resource: *const anyopaque, count: u64, shape: anytype) ?std.meta.Child(@TypeOf(shape)) {
    return text_storage.allocate([]const u8, resource, count, shape);
}

pub inline fn allocateOptionalTextSlots(resource: *const anyopaque, count: u64, shape: anytype) ?std.meta.Child(@TypeOf(shape)) {
    return text_storage.allocate(?[]const u8, resource, count, shape);
}

pub inline fn writeTextSlot(target: *anyopaque, index: u64, value: []const u8) void {
    text_storage.write([]const u8, target, index, value);
}

pub inline fn writeOptionalTextSlot(target: *anyopaque, index: u64, value: ?[]const u8) void {
    text_storage.write(?[]const u8, target, index, value);
}

pub inline fn borrowTextSlots(source: *const anyopaque, count: u64) []const []const u8 {
    return text_storage.borrow([]const u8, source, count);
}

pub inline fn borrowOptionalTextSlots(source: *const anyopaque, count: u64) []const ?[]const u8 {
    return text_storage.borrow(?[]const u8, source, count);
}

pub inline fn stringBufferSlots(source: *anyopaque, shape: anytype) std.meta.Child(@TypeOf(shape)) {
    const view: *[][]const u8 = @ptrCast(@alignCast(source));

    return @ptrCast(view.ptr);
}

pub inline fn requireAllocation(success: bool) std.mem.Allocator.Error!void {
    if (!success) return error.OutOfMemory;
}

pub inline fn stringViews(source: *const anyopaque) []const []const u8 {
    const view: *const []const []const u8 = @ptrCast(@alignCast(source));

    return view.*;
}

pub inline fn u32View(source: *anyopaque, shape: anytype) std.meta.Child(@TypeOf(shape)) {
    return @ptrCast(source);
}

pub inline fn u8ListViews(source: *const anyopaque) []const []const u8 {
    const view: *const []const []const u8 = @ptrCast(@alignCast(source));

    return view.*;
}

pub inline fn u32Views(source: *const anyopaque) []const u32 {
    const view: *const []const u32 = @ptrCast(@alignCast(source));

    return view.*;
}

pub inline fn u64Views(source: *const anyopaque) []const u64 {
    const view: *const []const u64 = @ptrCast(@alignCast(source));

    return view.*;
}

pub const u64ViewSlice = u64Views;

pub inline fn optionalU32Views(source: *const anyopaque) []const ?u32 {
    const view: *const []const ?u32 = @ptrCast(@alignCast(source));

    return view.*;
}

const rows = @import("rows.zig");
pub const NamedId = rows.NamedId;
pub const NamedColumns = rows.NamedColumns;
pub const readNamedColumnName = rows.readNamedColumnName;
pub const readNamedColumnId = rows.readNamedColumnId;
pub const borrowNamedRows = rows.borrow;
pub const bindNamedRowView = rows.bindNamedRowView;
pub const namedRowsView = rows.namedRowsView;
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
pub const readReferenceOptionalU32Range = reference_rows.Span(?u32).read;
pub const readReferenceTextRange = reference_rows.Span([]const u8).read;
pub const readReferenceOptionalTextRange = reference_rows.Span(?[]const u8).read;
pub const readReferenceTextListsRange = reference_rows.Span([]const []const u8).read;
pub const readReferenceOptionalTextListsRange = reference_rows.Span(?[]const []const u8).read;
pub const readReferenceOptionalNamedListsRange = reference_rows.Span(?[]const ?[]const u8).read;
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
pub const bindSliceColumns = rows.bindSliceColumns;
pub const sliceColumnCount = rows.sliceColumnCount;
pub const readSliceCell = rows.readSliceCell;
pub const ListProjection = rows.ListProjection;
pub const listProjectionSourceCount = rows.listProjectionSourceCount;
pub const listProjectionTargetCount = rows.listProjectionTargetCount;
pub const requireColumnBounds = rows.requireColumnBounds;
pub const projectListCell = rows.projectListCell;
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
pub const WriteColumn = column.Column;
pub const RowBuffer = column.RowBuffer;
pub const RowOutput = column.RowOutput;
pub const RowGrowth = column.RowGrowth;
pub const rowFieldCount = column.rowFieldCount;
pub const rowStorageCount = column.rowStorageCount;
pub const rowCapacityLimit = column.rowCapacityLimit;
pub const rowGrowthBase = column.rowGrowthBase;
pub const rowGrowthBuffer = column.rowGrowthBuffer;
pub const refreshRowWrite = column.refreshRowWrite;
pub const refreshRowRead = column.refreshRowRead;
pub const clearRowStorage = column.clearRowStorage;
pub const reserveRowStorage = column.reserveRowStorage;
pub const allocateRowStorage = column.allocateRowStorage;
pub const rowBufferBytes = column.rowBufferBytes;
pub const writeRowListCount = column.writeRowListCount;
pub const copyRow = column.copyRow;
pub const borrowWriteColumn = column.borrow;
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

pub inline fn copyU32s(target: *anyopaque, source: []const u32) error{IndexOutOfBounds}!void {
    return copySlice(u32, target, source);
}

inline fn copySlice(comptime T: type, target: *anyopaque, source: []const T) error{IndexOutOfBounds}!void {
    const buffer: *const []T = @ptrCast(@alignCast(target));

    if (buffer.len != source.len) return error.IndexOutOfBounds;

    @memmove(buffer.*, source);
}

pub inline fn writeU32(target: *anyopaque, index: u64, value: u32) error{IndexOutOfBounds}!void {
    return write(u32, target, index, value);
}

pub const SourceSpan = struct {
    start: usize,
    end: usize,
};

pub inline fn writeOptionalString(target: *anyopaque, index: u64, value: ?[]const u8) error{IndexOutOfBounds}!void {
    return write(?[]const u8, target, index, value);
}

// The caller exclusively lends a descriptor for a mutable slice for the duration of the call.
inline fn write(comptime T: type, target: *anyopaque, index: u64, value: T) error{IndexOutOfBounds}!void {
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

pub const readU32View = readU32;

pub inline fn readU64(target: *const anyopaque, index: u64) error{IndexOutOfBounds}!u64 {
    return read(u64, target, index);
}

pub const readU64View = readU64;

inline fn read(comptime T: type, target: *const anyopaque, index: u64) error{IndexOutOfBounds}!T {
    const buffer: *const []T = @ptrCast(@alignCast(target));

    if (index >= buffer.len) return error.IndexOutOfBounds;

    return buffer.*[@intCast(index)];
}
