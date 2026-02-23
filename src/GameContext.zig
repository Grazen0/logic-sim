const std = @import("std");
const structs = @import("./structs/structs.zig");
const core = @import("./core.zig");

const Self = @This();

const Allocator = std.mem.Allocator;
const SlotMap = structs.SlotMap;
const CustomModule = core.CustomModule;

pub const NextScene = union(enum) {
    selector: struct {
        delete_mod: ?CustomModule.Key,
    },
    editor: CustomModule.Key,
};

next_scene: ?NextScene,

pub fn init() Self {
    return .{
        .next_scene = null,
    };
}
