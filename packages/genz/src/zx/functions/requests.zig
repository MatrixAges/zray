const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const generated = @import("genz_options").generated_analysis;
const Seed = @import("requests/seed.zig");
const creating = @import("generated_function_requests_create");
const pushing = @import("generated_function_requests_push");
const taking = if (generated) @import("generated_function_requests_take") else void;
const State = if (generated) @typeInfo(@typeInfo(@TypeOf(creating.executeState)).@"fn".return_type.?).error_union.payload else Seed;
const Self = @This();

pub const Variant = enum {
    regular,
    value,
    pub fn member(self: Variant) []const u8 {
        if (!generated) return switch (self) {
            .regular => "call",
            .value => "callValue",
        };

        var fixed = std.heap.FixedBufferAllocator.init(&.{});

        return @import("generated_function_reference_member").executeIn(fixed.allocator(), switch (self) {
            .regular => .Regular,
            .value => .Value,
        }) catch unreachable;
    }
    pub fn name(self: Variant, allocator: std.mem.Allocator, id: ir.FunctionId) std.mem.Allocator.Error![]const u8 {
        if (!generated) return if (self == .regular)
            std.fmt.allocPrint(allocator, "function_{d}", .{@backingInt(id)})
        else
            std.fmt.allocPrint(allocator, "function_{d}_{s}", .{ @backingInt(id), @tagName(self) });

        const naming = @import("generated_function_reference_name");

        const input: std.meta.Child(naming.Input) = .{
            .id = @backingInt(id),
            .variant = switch (self) {
                .regular => .Regular,
                .value => .Value,
            },
        };

        return naming.executeIn(allocator, &input) catch |err| return failure(err);
    }
};

pub const Item = struct { id: ir.FunctionId, variant: Variant, first: bool };
pub const Form = if (generated) @FieldType(std.meta.Child(taking.Output), "form") else enum { Done, Native, FirstRegular, Regular, FirstValue, Value };
pub const Request = struct { id: ir.FunctionId, form: Form };

state: State,
pub fn init(allocator: std.mem.Allocator, size: usize) std.mem.Allocator.Error!Self {
    if (!generated) return .{ .state = try Seed.init(allocator, size) };

    return .{ .state = creating.executeState(allocator, size) catch |err| return failure(err) };
}

pub fn add(self: *Self, allocator: std.mem.Allocator, id: ir.FunctionId, variant: Variant) std.mem.Allocator.Error!void {
    if (!generated) return self.state.add(allocator, id, variant);

    self.state = pushing.executeState(allocator, .{
        .state = self.state,
        .id = @backingInt(id),
        .variant = switch (variant) {
            .regular => .Regular,
            .value => .Value,
        },
    }) catch |err| return failure(err);
}

pub fn next(self: *Self, native_modules: []const ?u32) ?Request {
    if (!generated) {
        const cursor = self.state.next;

        if (cursor == self.state.items.items.len) return null;

        const item = self.state.items.items[cursor];

        self.state.next += 1;

        const form: Form = if (native_modules[@backingInt(item.id)] != null) .Native else switch (item.variant) {
            .regular => if (item.first) .FirstRegular else .Regular,
            .value => if (item.first) .FirstValue else .Value,
        };

        return .{ .id = item.id, .form = form };
    }

    var cursor: []u64 = @as(*[1]u64, @ptrCast(&self.state.next));

    const input: std.meta.Child(taking.Input) = .{
        .ids = self.state.ids.items,
        .forms = self.state.forms.items,
        .next = self.state.next,
        .native_modules = native_modules,
        .cursor = @ptrCast(&cursor),
    };

    var fixed = std.heap.FixedBufferAllocator.init(&.{});
    const result = zx.columns.invoke(taking.executeValue, fixed.allocator(), &input) catch unreachable;

    if (result.form == .Done) return null;

    return .{ .id = @fromBackingInt(result.id), .form = result.form };
}

fn failure(err: anyerror) std.mem.Allocator.Error {
    if (err == error.OutOfMemory) return error.OutOfMemory;

    std.debug.panic("function request state failed: {s}", .{@errorName(err)});
}
