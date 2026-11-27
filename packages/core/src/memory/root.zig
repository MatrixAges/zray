const std = @import("std");
const sha256 = @import("sha256.zig");
pub const sha256Into = sha256.into;
pub const sha256FramedInto = sha256.framedInto;
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
pub const storeAtomicCell = AtomicRows.store;
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
pub const ColumnRange = column_range.Range;
pub const ColumnRanges = column_range.Ranges;
pub const bindColumnRanges = column_range.bind;
pub const ColumnRangeGroup = column_range.Group;
pub const columnRangeSlotCount = column_range.columns;
pub const columnRangeLength = column_range.length;
pub const columnRangeU8Tail = column_range.tailAt;
pub const columnRangeU32Tail = column_range.tailAt;
pub const columnRangeOptionalU32Tail = column_range.tailAt;
pub const columnRangeCount = column_range.count;
pub const setColumnRangeCount = column_range.setCount;
pub const reserveColumnRange = column_range.reserveOne;
pub const publishColumnRange = column_range.publishOne;
pub const bindRangeWriteColumn = column_range.bindWriteColumn;
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
pub const allocateColumnU32s = column_set.allocateU32s;
pub const writeColumnU32s = writeU32;
pub const copyColumnText = column_set.copyText;
pub const copyColumnBytes = column_set.copyText;
pub const copyColumnTextViews = column_set.copyTextViews;
pub const appendU64 = column_set.appendU64;
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

pub const readStringViews = stringViews;

pub inline fn u32View(source: *anyopaque, shape: anytype) std.meta.Child(@TypeOf(shape)) {
    return @ptrCast(source);
}

pub inline fn u64View(source: *anyopaque, shape: anytype) std.meta.Child(@TypeOf(shape)) {
    return @ptrCast(source);
}

pub fn allocateStringViews(allocator: std.mem.Allocator, target: *anyopaque, count: u64) std.mem.Allocator.Error!void {
    try allocateViews([]const u8, allocator, target, count);
}

pub fn allocateBoolViews(allocator: std.mem.Allocator, target: *anyopaque, count: u64) std.mem.Allocator.Error!void {
    try allocateViews(bool, allocator, target, count);
}

pub fn allocateU32Views(allocator: std.mem.Allocator, target: *anyopaque, count: u64) std.mem.Allocator.Error!void {
    try allocateViews(u32, allocator, target, count);
}

pub fn allocateU64Views(allocator: std.mem.Allocator, target: *anyopaque, count: u64) std.mem.Allocator.Error!void {
    try allocateViews(u64, allocator, target, count);
}

pub inline fn allocateU64Buffer(resource: *const anyopaque, target: *anyopaque, count: u64) std.mem.Allocator.Error!void {
    try allocateU64Views(column_set.borrowAllocator(resource), target, count);
}

pub inline fn allocateU8Buffer(resource: *const anyopaque, target: *anyopaque, count: u64) std.mem.Allocator.Error![]const u8 {
    try allocateViews(u8, column_set.borrowAllocator(resource), target, count);

    return u8Views(target);
}

fn allocateViews(comptime T: type, allocator: std.mem.Allocator, target: *anyopaque, count: u64) std.mem.Allocator.Error!void {
    const output: *[]T = @ptrCast(@alignCast(target));
    output.* = try allocator.alloc(T, std.math.cast(usize, count) orelse return error.OutOfMemory);
}

pub inline fn u8Views(source: *const anyopaque) []const u8 {
    const view: *const []const u8 = @ptrCast(@alignCast(source));

    return view.*;
}

pub inline fn u8ListViews(source: *const anyopaque) []const []const u8 {
    const view: *const []const []const u8 = @ptrCast(@alignCast(source));

    return view.*;
}

pub inline fn reserveU8Tail(resource: *const anyopaque, storage: *anyopaque, source: *anyopaque, tail: *anyopaque, count: u64, limit: u64) std.mem.Allocator.Error!void {
    try column_set.reserveTail(u8, resource, storage, source, tail, count, limit);
}

pub inline fn reserveU32Tail(resource: *const anyopaque, storage: *anyopaque, source: *anyopaque, tail: *anyopaque, count: u64, limit: u64) std.mem.Allocator.Error!void {
    try column_set.reserveTail(u32, resource, storage, source, tail, count, limit);
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

pub inline fn refreshOptionalU32View(target: *anyopaque, source: *const anyopaque) void {
    const view: *[]const ?u32 = @ptrCast(@alignCast(target));
    view.* = optionalU32Views(source);
}

pub inline fn borrowOptionalU32Range(source: []const ?u32, first: u64, count: u64) error{IndexOutOfBounds}![]const ?u32 {
    return borrowRange(?u32, source, first, count);
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
pub const appendByteView = reference_rows.appendByteView;
pub const popByteView = reference_rows.popByteView;
pub const IndirectTextColumn = rows.IndirectTextColumn;
pub const ReadColumn = rows.ReadColumn;
pub const ListColumn = rows.ListColumn;
pub const borrowProjectedText = rows.borrowProjectedText;
pub const borrowTextColumn = rows.borrowText;
pub const borrowTextSlice = rows.borrowTextSlice;

pub fn bindTextView(target: *anyopaque, source: *const anyopaque, shape: anytype) std.meta.Child(@TypeOf(shape)) {
    const view: *TextColumn = @ptrCast(@alignCast(target));
    view.* = borrowTextSlice(stringViews(source));

    return @ptrCast(view);
}

pub inline fn textColumnView(source: *anyopaque, shape: anytype) std.meta.Child(@TypeOf(shape)) {
    return @ptrCast(source);
}

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
pub const writeNamedRow = rows.write;
pub const allocateNamedRows = rows.allocateNamedRows;
const column = @import("write_column.zig");
const field_columns = @import("field_columns.zig");
pub const borrowReadFields = field_columns.borrowRead;
pub const borrowWriteFields = field_columns.borrowWrite;
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
pub const trimRowStorage = column.trimRowStorage;
pub const allocateRowStorage = column.allocateRowStorage;
pub const rowBufferBytes = column.rowBufferBytes;
pub const writeRowList = column.writeRowList;
pub const writeRowListCount = column.writeRowListCount;
pub const copyRow = column.copyRow;
pub const writeRow = column.writeRow;
pub const writeRowIndex = column.writeRowIndex;
pub const writeRowByteView = column.writeRowByteView;
pub const writeRowByteField = column.writeRowByteField;
pub const copyRowPrefix = column.copyRowPrefix;
pub const borrowWriteColumn = column.borrow;
pub const borrowNestedWriteColumn = column.borrowNested;
pub const writeColumnU8 = column.writeU8;
pub const writeColumnU32 = column.writeU32;
pub const writeColumnU64 = column.writeU64;
pub const writeColumnIndex = column.writeIndex;
pub const writeColumnBool = column.writeBool;
pub const writeColumnOptionalBool = column.writeOptionalBool;
pub const writeColumnBytes = column.writeBytes;
pub const writeColumnU32List = column.writeU32List;
pub const writeColumnU64List = column.writeU64List;
pub const writeColumnU32Lists = column.writeU32Lists;
pub const writeColumnOptionalU32 = column.writeOptionalU32;
pub const writeColumnOptionalU8 = column.writeOptionalU8;
pub const writeColumnOptionalText = column.writeOptionalText;
pub const writeColumnTextList = column.writeTextList;
pub const writeColumnRowReference = column.writeRowReference;
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

pub inline fn copyBytes(target: *anyopaque, offset: u64, source: []const u8, start: u64, end: u64) error{IndexOutOfBounds}!u64 {
    return copyRange(u8, target, offset, source, start, end);
}

pub inline fn copyU32Range(target: *anyopaque, offset: u64, source: []const u32, start: u64, end: u64) error{IndexOutOfBounds}!void {
    _ = try copyRange(u32, target, offset, source, start, end);
}

inline fn copyRange(comptime T: type, target: *anyopaque, offset: u64, source: []const T, start: u64, end: u64) error{IndexOutOfBounds}!u64 {
    const output: *const []T = @ptrCast(@alignCast(target));

    if (start > end or end > source.len or offset > output.len) return error.IndexOutOfBounds;

    const count = end - start;

    if (count > output.len - offset) return error.IndexOutOfBounds;

    @memmove(output.*[@intCast(offset)..][0..@intCast(count)], source[@intCast(start)..@intCast(end)]);

    return count;
}

pub inline fn copyU8s(target: *anyopaque, source: []const u8) error{IndexOutOfBounds}!void {
    return copySlice(u8, target, source);
}

pub inline fn copyBools(target: *anyopaque, source: []const bool) error{IndexOutOfBounds}!void {
    const buffer: *const []bool = @ptrCast(@alignCast(target));

    if (buffer.len != source.len) return error.IndexOutOfBounds;
    if (buffer.ptr == source.ptr) return;

    @memmove(buffer.*, source);
}

pub inline fn copyU32s(target: *anyopaque, source: []const u32) error{IndexOutOfBounds}!void {
    return copySlice(u32, target, source);
}

pub inline fn copyU32sAt(target: *anyopaque, offset: u64, source: []const u32) error{IndexOutOfBounds}!void {
    return copySliceAt(u32, target, offset, source);
}

pub inline fn copyStringViewsAt(target: *anyopaque, offset: u64, source: []const []const u8) error{IndexOutOfBounds}!void {
    return copySliceAt([]const u8, target, offset, source);
}

inline fn copySliceAt(comptime T: type, target: *anyopaque, offset: u64, source: []const T) error{IndexOutOfBounds}!void {
    const buffer: *const []T = @ptrCast(@alignCast(target));

    if (offset > buffer.len or source.len > buffer.len - offset) return error.IndexOutOfBounds;

    @memmove(buffer.*[@intCast(offset)..][0..source.len], source);
}

pub inline fn copyStringViews(target: *anyopaque, source: []const []const u8) error{IndexOutOfBounds}!void {
    return copySlice([]const u8, target, source);
}

pub inline fn copyText(allocator: std.mem.Allocator, value: []const u8) std.mem.Allocator.Error![]const u8 {
    return allocator.dupe(u8, value);
}

inline fn copySlice(comptime T: type, target: *anyopaque, source: []const T) error{IndexOutOfBounds}!void {
    const buffer: *const []T = @ptrCast(@alignCast(target));

    if (buffer.len != source.len) return error.IndexOutOfBounds;

    @memmove(buffer.*, source);
}

pub inline fn writeU32(target: *anyopaque, index: u64, value: u32) error{IndexOutOfBounds}!void {
    return write(u32, target, index, value);
}

pub inline fn u32BufferLength(source: *const anyopaque) u64 {
    const view: *const []u32 = @ptrCast(@alignCast(source));

    return view.len;
}

pub fn allocateU32Buffer(resource: *const anyopaque, target: *anyopaque, count: u64) std.mem.Allocator.Error!void {
    return allocateFilledU32Buffer(resource, target, count, 0);
}

pub fn allocateFilledU32Buffer(resource: *const anyopaque, target: *anyopaque, count: u64, value: u32) std.mem.Allocator.Error!void {
    const allocator: *const std.mem.Allocator = @ptrCast(@alignCast(resource));
    const output: *[]u32 = @ptrCast(@alignCast(target));

    std.debug.assert(output.len == 0);

    const items = try allocator.alloc(u32, std.math.cast(usize, count) orelse return error.OutOfMemory);

    @memset(items, value);

    output.* = items;
}

pub inline fn swapU32Buffers(left: *anyopaque, right: *anyopaque) void {
    swapBuffers(u32, left, right);
}

pub inline fn swapU64Buffers(left: *anyopaque, right: *anyopaque) void {
    swapBuffers(u64, left, right);
}

pub inline fn releaseU32Buffer(resource: *const anyopaque, target: *anyopaque) void {
    releaseBuffer(u32, resource, target);
}

pub inline fn releaseU64Buffer(resource: *const anyopaque, target: *anyopaque) void {
    releaseBuffer(u64, resource, target);
}

inline fn swapBuffers(comptime T: type, left: *anyopaque, right: *anyopaque) void {
    const first: *[]T = @ptrCast(@alignCast(left));
    const second: *[]T = @ptrCast(@alignCast(right));

    std.mem.swap([]T, first, second);
}

inline fn releaseBuffer(comptime T: type, resource: *const anyopaque, target: *anyopaque) void {
    const output: *[]T = @ptrCast(@alignCast(target));

    column_set.borrowAllocator(resource).free(output.*);

    output.* = &.{};
}

pub inline fn writeStatementKind(target: *anyopaque, index: u64, kind: anytype) error{IndexOutOfBounds}!void {
    comptime std.debug.assert(@sizeOf(@TypeOf(kind)) == @sizeOf(u8));

    return writeU8(target, index, @backingInt(kind));
}

pub inline fn writeU8(target: *anyopaque, index: u64, value: u8) error{IndexOutOfBounds}!void {
    return write(u8, target, index, value);
}

pub inline fn writeBool(target: *anyopaque, index: u64, value: bool) error{IndexOutOfBounds}!void {
    return write(bool, target, index, value);
}

pub inline fn boolViews(source: *const anyopaque) []const bool {
    const view: *const []bool = @ptrCast(@alignCast(source));

    return view.*;
}

pub inline fn fillByteRange(target: *anyopaque, first: u64, count: u64, value: u8) error{IndexOutOfBounds}!void {
    const output: *const []u8 = @ptrCast(@alignCast(target));

    if (first > output.len or count > output.len - first) return error.IndexOutOfBounds;

    @memset(output.*[@intCast(first)..][0..@intCast(count)], value);
}

pub inline fn writeU64(target: *anyopaque, index: u64, value: u64) error{IndexOutOfBounds}!void {
    return write(u64, target, index, value);
}

pub inline fn writeIndex(target: *anyopaque, index: u64, value: u64) error{IndexOutOfBounds}!void {
    return write(usize, target, index, std.math.cast(usize, value) orelse return error.IndexOutOfBounds);
}

pub inline fn clearOptionalU8Range(target: *anyopaque, first: u64, end: u64) error{IndexOutOfBounds}!void {
    return fillRange(?u8, target, first, end, null);
}

pub inline fn clearOptionalU16Range(target: *anyopaque, first: u64, end: u64) error{IndexOutOfBounds}!void {
    return fillRange(?u16, target, first, end, null);
}

pub const SourceSpan = struct {
    start: usize,
    end: usize,
};

pub inline fn fillSourceSpanRange(target: *anyopaque, first: u64, end: u64, start_offset: u64, end_offset: u64) error{IndexOutOfBounds}!void {
    return fillRange(SourceSpan, target, first, end, .{
        .start = std.math.cast(usize, start_offset) orelse return error.IndexOutOfBounds,
        .end = std.math.cast(usize, end_offset) orelse return error.IndexOutOfBounds,
    });
}

inline fn fillRange(comptime T: type, target: *anyopaque, first: u64, end: u64, value: T) error{IndexOutOfBounds}!void {
    const view: *const []T = @ptrCast(@alignCast(target));

    if (first > end or end > view.len) return error.IndexOutOfBounds;

    @memset(view.*[@intCast(first)..@intCast(end)], value);
}

pub inline fn clearU64Buffer(target: *anyopaque) void {
    const output: *const []u64 = @ptrCast(@alignCast(target));

    @memset(output.*, 0);
}

pub inline fn writeOptionalU32(target: *anyopaque, index: u64, value: ?u32) error{IndexOutOfBounds}!void {
    return write(?u32, target, index, value);
}

pub inline fn writeOptionalU16(target: *anyopaque, index: u64, value: ?u16) error{IndexOutOfBounds}!void {
    return write(?u16, target, index, value);
}

pub inline fn writeOptionalU8(target: *anyopaque, index: u64, value: ?u8) error{IndexOutOfBounds}!void {
    return write(?u8, target, index, value);
}

pub fn allocateOptionalU32Buffer(allocator: std.mem.Allocator, target: *anyopaque, count: u64, clear: bool) std.mem.Allocator.Error!void {
    const output: *[]?u32 = @ptrCast(@alignCast(target));
    const size = std.math.cast(usize, count) orelse return error.OutOfMemory;
    const items = try allocator.alloc(?u32, size);

    std.debug.assert(output.len == 0);

    if (clear) @memset(items, null);

    output.* = items;
}

pub inline fn allocateOptionalU32WithAllocator(resource: *const anyopaque, target: *anyopaque, count: u64, clear: bool) std.mem.Allocator.Error!void {
    return allocateOptionalU32Buffer(column_set.borrowAllocator(resource), target, count, clear);
}

pub inline fn bindU32Range(source: *const anyopaque, target: *anyopaque, first: u64, count: u64) error{IndexOutOfBounds}!void {
    const input: *const []u32 = @ptrCast(@alignCast(source));
    const output: *[]u32 = @ptrCast(@alignCast(target));

    if (first > input.len or count > input.len - first) return error.IndexOutOfBounds;

    output.* = input.*[@intCast(first)..][0..@intCast(count)];
}

pub inline fn writeString(target: *anyopaque, index: u64, value: []const u8) error{IndexOutOfBounds}!void {
    return write([]const u8, target, index, value);
}

pub inline fn writeOptionalString(target: *anyopaque, index: u64, value: ?[]const u8) error{IndexOutOfBounds}!void {
    return write(?[]const u8, target, index, value);
}

pub inline fn initializeU32ListSlot(target: *anyopaque, index: u64, shape: anytype) error{IndexOutOfBounds}!std.meta.Child(@TypeOf(shape)) {
    const output: *const [][]const u32 = @ptrCast(@alignCast(target));

    if (index >= output.len) return error.IndexOutOfBounds;

    const slot = &output.*[@intCast(index)];

    slot.* = &.{};

    return @ptrCast(slot);
}

pub inline fn writeU8List(target: *anyopaque, index: u64, value: []const u8) error{IndexOutOfBounds}!void {
    return write([]const u8, target, index, value);
}

pub inline fn writeU32List(target: *anyopaque, index: u64, value: []const u32) error{IndexOutOfBounds}!void {
    return write([]const u32, target, index, value);
}

pub inline fn writeStringList(target: *anyopaque, index: u64, value: []const []const u8) error{IndexOutOfBounds}!void {
    return write([]const []const u8, target, index, value);
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
