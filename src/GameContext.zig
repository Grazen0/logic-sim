const std = @import("std");
const structs = @import("./structs/structs.zig");
const Module = @import("./Module.zig");

const Self = @This();

const Allocator = std.mem.Allocator;
const SlotMap = structs.SlotMap;

pub const NextScene = union(enum) {
    selector,
    editor: Module.Key,
};

modules: SlotMap(Module),
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
