const std = @import("std");
const ir = @import("zx").ir;
const Lower = @import("../lower.zig");
const evaluate = @import("evaluate.zig");
const borrow = evaluate.borrow;
const projection = @import("../access/projection/read.zig");
const path = @import("../access/projection/path.zig");
const list = @import("../state_value/list.zig");
const Error = Lower.Error;

pub fn readReference(frame: *anyopaque, symbol: u32, result_type: u32, iteration: bool) Error!u32 {
    return @backingInt(try @import("../access/reference.zig").lowerMode(borrow(frame), @fromBackingInt(symbol), @fromBackingInt(result_type), iteration));
}

pub fn readTupleResult(frame: *anyopaque, operand: u32, index: u32) Error!?u32 {
    const value = try @import("../collections.zig").projection(borrow(frame), @fromBackingInt(operand), index);

    return if (value) |id| @backingInt(id) else null;
}

pub fn readRawMember(frame: *anyopaque, operand: u32) Error!?u32 {
    const self = borrow(frame);
    const type_id: ir.TypeId = @fromBackingInt(self.program.expressions.types[operand]);

    if (!@import("../access/projection/rules.zig").raw(self, type_id, false)) return null;

    const value = try path.lower(self, @fromBackingInt(operand));

    return if (value) |id| @backingInt(id) else null;
}

pub fn readAnchor(frame: *anyopaque, operand: u32) Error!u32 {
    return @backingInt(try path.anchor(borrow(frame), @fromBackingInt(operand)));
}

pub fn readMember(frame: *anyopaque, row: u32, source: u32, raw: bool, iteration: bool) Error!u32 {
    const self = borrow(frame);
    const table = &self.program.expressions;
    const payload = table.payloads[row];
    const target = table.projection_targets[payload];
    const item: ir.Projection = .{ .target = @fromBackingInt(target), .index = table.projection_indices[payload] };

    return @backingInt(try projection.resolvedMember(self, @fromBackingInt(table.types[row]), @fromBackingInt(table.types[target]), item, @fromBackingInt(source), raw, table.kinds[row] == .TupleField, iteration));
}

pub fn readRawList(frame: *anyopaque, operand: u32) Error!?u32 {
    const value = try path.nested(borrow(frame), @fromBackingInt(operand));

    return if (value) |id| @backingInt(id) else null;
}

pub fn readList(frame: *anyopaque, operand: u32) Error!u32 {
    return @backingInt(try list.expression(borrow(frame), @fromBackingInt(operand)));
}

pub fn readBorrowedList(frame: *anyopaque, type_id: u32, value: u32) Error!u32 {
    return @backingInt(try list.borrowed(borrow(frame), @fromBackingInt(type_id), @fromBackingInt(value)));
}

pub fn readRepresentedValue(frame: *anyopaque, type_id: u32, value: u32) Error!u32 {
    return @backingInt(try @import("../state_value/conversion.zig").read(borrow(frame), @fromBackingInt(type_id), @fromBackingInt(value)));
}

pub fn wrapLoweredList(frame: *anyopaque, subject: u32, items: u32) Error!u32 {
    const self = borrow(frame);
    const type_id = self.program.expression(@fromBackingInt(subject)).type_id;

    return @backingInt(try list.wrap(self, type_id, @fromBackingInt(items), false));
}

pub fn readIndex(frame: *anyopaque, source: u32, key: u32) Error!u32 {
    return @backingInt(try @import("../intrinsics.zig").index(borrow(frame), @fromBackingInt(source), @fromBackingInt(key)));
}

pub fn readIndexResult(frame: *anyopaque, result_type: u32, operand: u32, value: u32, raw: bool) Error!u32 {
    return @backingInt(try projection.resolvedIndex(borrow(frame), @fromBackingInt(result_type), @fromBackingInt(operand), @fromBackingInt(value), raw));
}
