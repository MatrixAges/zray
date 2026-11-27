const std = @import("std");
const zx = @import("zx");
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const OriginBuffer = @import("../construction/publication.zig").OriginBuffer;
const publication = @import("../construction/publication.zig");
const generated = @import("genz_options").generated_analysis;
const seed = @import("transaction_seed.zig");

pub fn active(self: *const Lower) bool {
    if (!generated) return seed.active(self);

    const entry = @import("generated_store_transaction");
    const Input = std.meta.Child(entry.Input);

    const input: Input = .{
        .mode = @fromBackingInt(@backingInt(self.program.store_mode)),
        .count = self.program.stores.count(),
    };

    var memory = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(entry.executeValue, memory.allocator(), &input) catch unreachable;
}

pub fn declaration(self: *Lower, output: *@import("../../node/declarations.zig").Output) Lower.Error!void {
    if (!generated) return seed.declaration(self, output);

    const entry = @import("generated_store_pending_type");
    const Input = std.meta.Child(entry.Input);
    const Types = std.meta.Child(@FieldType(Input, "types"));

    const request: Types = .{
        .frame = @ptrCast(self),
        .ids = self.program.stores.types,
    };

    const input: Input = .{
        .writer = @ptrCast(self),
        .declarations = @ptrCast(output),
        .types = &request,
        .name = self.pending_name,
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    return entry.executeIn(memory.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };
}

pub fn initialize(self: *Lower) Lower.Error!node.Block {
    if (!generated) {
        var body: std.ArrayList(node.Statement) = .empty;

        try seed.initialize(self, &body);

        return self.builder.statements(body.items);
    }

    const entry = @import("generated_store_pending_initial");
    const Input = std.meta.Child(entry.Input);
    const block = self.program.body.block();
    var origin: OriginBuffer = .{};

    const input: Input = .{
        .writer = @ptrCast(self),
        .origin = @ptrCast(&origin),
        .mode = @fromBackingInt(@backingInt(self.program.store_mode)),
        .store_count = self.program.stores.count(),
        .name = self.pending_name,
        .control = zx.columns.pointer(@FieldType(Input, "control"), block.control),
        .first = block.first,
        .count = block.len,
    };

    return publication.executeSpan(self, entry, &input);
}

pub fn finish(self: *Lower) Lower.Error!node.Block {
    const body = self.program.body;

    if (!generated) {
        if (seed.active(self) and !zx.ir.terminates(body.block())) return self.builder.statements(&.{.{ .expression = try seed.commit(self) }});

        return .{};
    }

    const entry = @import("generated_store_fallthrough");
    const Input = std.meta.Child(entry.Input);
    const Block = std.meta.Child(@FieldType(Input, "body"));

    const block: Block = .{
        .control = zx.columns.pointer(@FieldType(Block, "control"), body.control),
        .block = if (body.root) |root| @backingInt(root) else null,
    };

    const transaction: std.meta.Child(@FieldType(Input, "transaction")) = .{
        .mode = @fromBackingInt(@backingInt(self.program.store_mode)),
        .count = self.program.stores.count(),
    };

    var origin: OriginBuffer = .{};

    const input: Input = .{
        .transaction = &transaction,
        .body = &block,
        .writer = @ptrCast(self),
        .origin = @ptrCast(&origin),
    };

    return publication.executeSpan(self, entry, &input);
}
