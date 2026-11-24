const std = @import("std");
const frontend = @import("frontend");
const zx = @import("zx");
const rx = @import("rx");
const Builder = @import("../../program/builder.zig");
const expression = @import("../../expression.zig");
const Options = @import("../initializer.zig").Options;
const Self = @This();

pub const span: zx.Span = .{ .start = 0, .end = 0 };

const input_type = frontend.types.scalarId(.void);

const Field = struct {
    name: *const rx.ast.Attribute = undefined,
    value: *const rx.ast.Attribute = undefined,
    type_id: zx.ir.TypeId = undefined,
    parsed: ?frontend.ExpressionInput.Result = null,
    initial: ?expression.Result = null,
};

options: *const Options,
backing: std.mem.Allocator,
temporary: std.mem.Allocator,
builder: Builder,
fields: frontend.types.Fields = undefined,
names: [][]const u8 = undefined,
evaluation: []u32 = undefined,
field: Field = .{},
table: ?frontend.types = null,
reporter: zx.Reporter = .{},
output: zx.ir.TypeId = undefined,
program: zx.ir.Program = undefined,
diagnostic: ?expression.Diagnostic = null,
pub fn init(allocator: std.mem.Allocator, backing: std.mem.Allocator, temporary: std.mem.Allocator, options: *const Options) Self {
    return .{
        .options = options,
        .backing = backing,
        .temporary = temporary,
        .builder = .{ .allocator = allocator, .types = options.types.view(), .native_modules = options.native_modules },
    };
}

pub fn deinit(self: *Self) void {
    self.releaseField();
    self.builder.linking_scratch.deinit();

    if (self.table) |*table| self.options.types.* = table.items;
}

pub fn prepare(self: *Self, count: usize, comptime seed: bool) std.mem.Allocator.Error!void {
    self.fields = try frontend.types.Fields.init(self.builder.allocator, count);

    // The native constructor sorts its input in place.
    self.names = if (seed) try self.temporary.alloc([]const u8, count) else self.fields.names;
    self.evaluation = try self.temporary.alloc(u32, count);
    _ = try self.builder.symbol("in", input_type, span);
}

pub fn openField(self: *Self, row: usize, name: *const rx.ast.Attribute, value: *const rx.ast.Attribute) std.mem.Allocator.Error!void {
    self.field.name = name;
    self.field.value = value;
    self.field.type_id = self.options.field_types[row];
    self.field.parsed = try @import("../../attribute.zig").parseBorrowed(self.backing, value.*, self.options.owner);
}

pub fn compileField(self: *Self) std.mem.Allocator.Error!bool {
    const options = self.options;
    const field = &self.field;

    field.initial = try expression.compileParsed(self.backing, &field.parsed.?, field.value.*, .{
        .types = options.types.view(),
        .borrow_types = true,
        .type_storage = options.types,
        .type_allocator = self.builder.allocator,
        .native_modules = options.native_modules,
        .alias_columns = options.aliases,
        .expected = field.type_id,
        .scratch_backing = self.backing,
    }, false);

    if (field.initial.?.value == .diagnostic) {
        var issue = field.initial.?.value.diagnostic;
        issue.issue = try issue.issue.clone(self.builder.allocator);
        self.diagnostic = issue;

        return false;
    }

    return true;
}

pub fn recordField(self: *Self, position: usize, comptime seed: bool) std.mem.Allocator.Error!void {
    const name = try self.builder.allocator.dupe(u8, self.field.name.value);

    if (seed) self.names[position] = name;

    self.fields.set(position, name, self.field.type_id);
}

pub fn linkField(self: *Self, position: usize) std.mem.Allocator.Error!bool {
    const linked = @import("../../program/expression.zig").inlineValue(&self.builder, self.field.initial.?.value.ir, false) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        return false;
    };

    self.evaluation[position] = @backingInt(linked);

    return true;
}

pub fn releaseField(self: *Self) void {
    if (self.field.initial) |*initial| initial.deinit();
    if (self.field.parsed) |*parsed| parsed.deinit();

    self.field.initial = null;
    self.field.parsed = null;
}

pub fn resolveType(self: *Self) zx.Error!void {
    self.table = .{
        .allocator = self.builder.allocator,
        .reporter = &self.reporter,
        .declarations = &.{},
        .items = self.options.types.*,
    };

    self.output = try self.table.?.object(self.fields);
}

pub fn invalidLink(self: *Self) zx.Error {
    return self.reporter.fail(.contract, span, "Store initializer expression cannot be linked");
}

pub fn finishProgram(self: *Self, root: zx.ir.ExprId) std.mem.Allocator.Error!void {
    self.program = .{
        .file_name = self.options.owner,
        .types = self.table.?.items.view(),
        .native_modules = self.options.native_modules,
        .symbols = self.builder.symbols.view(),
        .expressions = self.builder.expressions.view(),
        .input_type = input_type,
        .output_type = self.output,
        .body = try zx.ir.ControlBody.fromValues(self.builder.allocator, &.{.{ .result = root }}),
    };
}

pub fn analyzeOwnership(self: *Self) zx.Error!void {
    self.program.output_ownership = try frontend.analyzeOwnership(self.builder.allocator, self.program, &self.reporter);
}

pub fn verifyProgram(self: *Self) zx.Error!void {
    if (try frontend.validateIr(self.builder.allocator, self.program)) |issue| return self.reporter.fail(issue.code, issue.span, issue.message);
}

pub fn report(self: *const Self) std.mem.Allocator.Error!expression.Diagnostic {
    return .{
        .location = self.options.layout.fragments[self.options.first].location,
        .issue = try self.reporter.diagnostic.?.clone(self.builder.allocator),
    };
}
