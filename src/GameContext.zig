const std = @import("std");
const structs = @import("./structs/structs.zig");
const core = @import("./core.zig");

const Self = @This();

const Allocator = std.mem.Allocator;
const SlotMap = structs.SlotMap;
const CustomModule = core.CustomModule;

pub const NextScene = union(enum) {
    selector,
    editor: CustomModule.Key,
};

modules: SlotMap(CustomModule),
next_scene: ?NextScene,

pub fn init() Self {
    return .{
        .modules = .empty,
        .next_scene = null,
    };
}

pub fn deinit(self: *Self, gpa: Allocator) void {
    var iter = self.modules.iterator();
    while (iter.nextValue()) |mod|
        mod.deinit(gpa);

    self.modules.deinit(gpa);
    self.* = undefined;
}
