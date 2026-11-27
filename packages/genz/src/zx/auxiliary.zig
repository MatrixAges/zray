const std = @import("std");
const zx = @import("zx");
const node = @import("../node.zig");
const stored = @import("../node/stored.zig");
const generated = @import("genz_options").generated_analysis;
const creating = @import("generated_auxiliary_create");
const State = if (generated) @typeInfo(@typeInfo(@TypeOf(creating.executeState)).@"fn".return_type.?).error_union.payload else std.ArrayList(node.Declaration);
const Self = @This();

state: State,
pub fn init() Self {
    if (!generated) return .{ .state = .empty };

    var fixed = std.heap.FixedBufferAllocator.init(&.{});
    const Parameter = @typeInfo(@TypeOf(creating.executeState)).@"fn".param_types[1].?;
    const input: Input(creating.executeState) = .{};

    return .{ .state = creating.executeState(fixed.allocator(), if (@typeInfo(Parameter) == .pointer) &input else input) catch unreachable };
}

pub fn count(self: *const Self) usize {
    return if (generated) self.state.tags.items.len else self.state.items.len;
}

pub fn append(self: *Self, allocator: std.mem.Allocator, value: node.Declaration) std.mem.Allocator.Error!void {
    return self.state.append(allocator, value);
}

pub fn replace(self: *Self, index: usize, value: node.Declaration) void {
    self.state.items[index] = value;
}

pub fn appendConstants(self: *Self, allocator: std.mem.Allocator, source: anytype, comptime borrow_text: bool) std.mem.Allocator.Error![]const []const u8 {
    const first = self.state.constant_name.items.len;

    if (source.offsets.len == 0) return self.state.constant_name.items[first..];

    const entry = @import("generated_auxiliary_constant");
    const Request = Input(entry.executeState);
    const Source = @FieldType(Request, "source");
    const columns = borrow(Child(Source), source.*);

    try self.apply(allocator, entry, .{
        .state = self.state,
        .source = if (@typeInfo(Source) == .pointer) &columns else columns,
        .borrow_text = borrow_text,
    });

    return self.state.constant_name.items[first..];
}

pub fn replaceConstant(self: *Self, allocator: std.mem.Allocator, index: usize, source: anytype) std.mem.Allocator.Error!void {
    const entry = @import("generated_auxiliary_replace");
    const Request = Input(entry.executeState);
    const Value = @FieldType(Request, "value");
    const value = borrow(Child(Value), constant(source, source.offsets[0]));

    return self.apply(allocator, entry, .{
        .state = self.state,
        .value = if (@typeInfo(Value) == .pointer) &value else value,
        .index = index,
    });
}

const Constant = struct { name: []const u8, type_expr: ?u32, value: u32, exported: bool };

fn constant(source: anytype, offset: u32) Constant {
    return .{
        .name = source.constant_name[offset],
        .type_expr = source.constant_type_expr[offset],
        .value = source.constant_value[offset],
        .exported = source.constant_exported[offset],
    };
}

pub fn appendFunction(self: *Self, allocator: std.mem.Allocator, source: anytype, parameter_base: u32) std.mem.Allocator.Error!void {
    const entry = @import("generated_auxiliary_function");
    const ValueField = @FieldType(Input(entry.executeState), "value");
    const value = borrow(Child(ValueField), source.*);

    const input: Input(entry.executeState) = .{
        .state = self.state,
        .value = if (@typeInfo(ValueField) == .pointer) &value else value,
        .parameter_base = parameter_base,
    };

    try self.apply(allocator, entry, input);
}

pub fn containsSeedFunction(self: *const Self, name: []const u8) bool {
    for (self.state.items) |value| {
        if (value == .function and std.mem.eql(u8, value.function.name, name)) return true;
    }

    return false;
}

pub fn functionNames(self: *const Self) []const []const u8 {
    return self.state.function_name.items;
}

pub fn store(self: *const Self, allocator: std.mem.Allocator, nodes: *@import("../node/storage.zig")) std.mem.Allocator.Error!stored.Declarations {
    if (!generated) return nodes.declarations(allocator, self.state.items);

    const View = Child(creating.Output);
    var columns: View = undefined;

    inline for (@typeInfo(View).@"struct".field_names) |name| @field(columns, name) = @field(self.state, name).items;

    const start: u32 = @intCast(nodes.declaration_rows.tags.items.len);

    @import("../node/import_rows.zig").appendBorrowingText(allocator, &nodes.declaration_rows, &columns) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidAst => @panic("invalid auxiliary declaration columns"),
    };

    return .{ .start = start, .len = @intCast(self.count()) };
}

pub fn assembleSeed(self: *const Self, allocator: std.mem.Allocator, nodes: *@import("../node/storage.zig"), prefix: *@import("../node/declarations.zig").Output, suffix: *@import("../node/declarations.zig").Output) std.mem.Allocator.Error!stored.Declarations {
    const first = try nodes.declarations(allocator, prefix.items);
    const middle = try self.store(allocator, nodes);
    const last = try nodes.declarations(allocator, suffix.items);

    std.debug.assert(first.start + first.len == middle.start);
    std.debug.assert(middle.start + middle.len == last.start);

    return .{ .start = first.start, .len = first.len + middle.len + last.len };
}

fn apply(self: *Self, allocator: std.mem.Allocator, comptime entry: type, input: Input(entry.executeState)) std.mem.Allocator.Error!void {
    const parameter = @typeInfo(@TypeOf(entry.executeState)).@"fn".param_types[1].?;
    const output = entry.executeState(allocator, if (@typeInfo(parameter) == .pointer) &input else input) catch |err| return failure(err);

    if (!output.valid) return error.OutOfMemory;

    self.state = output.state;
}

fn Child(comptime Value: type) type {
    return if (@typeInfo(Value) == .pointer) std.meta.Child(Value) else Value;
}

fn Input(comptime function: anytype) type {
    return Child(@typeInfo(@TypeOf(function)).@"fn".param_types[1].?);
}

fn borrow(comptime Target: type, source: anytype) Target {
    if (Target == @TypeOf(source)) return source;

    if (@typeInfo(Target) == .@"struct") {
        if (@hasField(Target, "items") and @hasField(Target, "storage")) return .{
            .items = @import("../node/view.zig").slice(@FieldType(Target, "items"), source),
            .storage = .plain,
        };

        var result: Target = undefined;

        inline for (@typeInfo(Target).@"struct".field_names) |name| {
            @field(result, name) = if (comptime std.mem.eql(u8, name, "zx_origin")) null else borrow(@FieldType(Target, name), @field(source, name));
        }

        return result;
    }

    return zx.columns.storage.view(Target, source);
}

fn failure(err: anyerror) std.mem.Allocator.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => @panic("invalid auxiliary declaration operation"),
    };
}
