const std = @import("std");
const zx = @import("zx");

pub const Type = if (@import("genz_options").generated_analysis)
    std.meta.Child(@FieldType(std.meta.Child(@import("generated_function_facts").Output), "layout_types"))

else
    u8;

pub const Property = if (@import("genz_options").generated_analysis)
    @FieldType(std.meta.Child(@import("generated_layout_query").Input), "property")

else
    u8;

pub fn query(value: Type, property: Property) bool {
    const values = comptime queries();

    return values[@backingInt(value)][@backingInt(property)];
}

fn queries() [@typeInfo(Type).@"enum".field_names.len][@typeInfo(Property).@"enum".field_names.len]bool {
    const generated = @import("generated_layout_query");
    var values: [@typeInfo(Type).@"enum".field_names.len][@typeInfo(Property).@"enum".field_names.len]bool = undefined;

    for (std.enums.values(Type)) |value| {
        for (std.enums.values(Property)) |property| {
            const input: std.meta.Child(generated.Input) = .{ .value = value, .property = property };

            values[@backingInt(value)][@backingInt(property)] = zx.columns.invoke(generated.executeValue, std.heap.page_allocator, &input) catch unreachable;
        }
    }

    return values;
}
