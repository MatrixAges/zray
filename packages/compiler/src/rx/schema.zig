const dsl = @import("dsl");

pub const builders = if (@import("rx_options").generated_rules)
    dsl.schemaWith(@import("schema/structure/adapter.zig"))

else
    dsl;
