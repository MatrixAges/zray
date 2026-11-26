const std = @import("std");
pub const bind = @import("generated_artifact_binding");
pub const publish = @import("generated_artifact_body_publish");
pub const Binding = std.meta.Child(bind.Input);
pub const PublishInput = std.meta.Child(publish.Input);
pub const PublishOutput = std.meta.Child(@typeInfo(publish.Output).optional.child);
pub const Retained = @typeInfo(@FieldType(PublishOutput, "entry")).optional.child;
