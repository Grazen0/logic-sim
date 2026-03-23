const std = @import("std");
const rl = @import("raylib");
const rg = @import("raygui");
const structs = @import("./structs/structs.zig");
const scenes = @import("./scenes/scenes.zig");
const consts = @import("./consts.zig");
const globals = @import("./globals.zig");
const theme = @import("./theme.zig");
const GameContext = @import("./GameContext.zig");
const user_dirs = @import("./user_dirs.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const SlotMap = structs.SlotMap;

const assert = std.debug.assert;

const Scene = union(enum) {
    selector: scenes.Selector,
    editor: scenes.Editor,

    pub fn deinit(self: *@This(), gpa: Allocator) void {
        switch (self.*) {
            .selector => |*sel| sel.deinit(gpa),
            .editor => |*ed| ed.deinit(gpa),
        }

        self.* = undefined;
    }

    pub fn frame(self: *@This(), gpa: Allocator) !void {
        switch (self.*) {
            .selector => |*sel| try sel.frame(gpa),
            .editor => |*ed| try ed.frame(gpa),
        }
    }
};

extern fn emscripten_run_script(ptr: [*c]const u8) void;

pub fn main() anyerror!void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const alloc = if (consts.web_build) std.heap.c_allocator else gpa.allocator();
    defer assert(!gpa.detectLeaks());

    defer {
        var iter = globals.modules.iterator();
        while (iter.nextValue()) |mod|
            mod.deinit(alloc);

        globals.modules.deinit(alloc);
    }

    rl.setConfigFlags(.{
        .msaa_4x_hint = true,
    });
    rl.initWindow(consts.screen_width, consts.screen_height, "Logic Simulator");
    defer rl.closeWindow();

    rl.setExitKey(.null);
    theme.loadStyle();
    rl.setTargetFPS(consts.target_fps);

    var ctx: GameContext = .init();

    try globals.loadCustomModules(alloc);

    var cur_scene: Scene = .{ .selector = try .init(alloc, &ctx) };
    defer cur_scene.deinit(alloc);

    while (!rl.windowShouldClose()) {
        rl.beginDrawing();
        defer rl.endDrawing();

        ctx.next_scene = null;
        try cur_scene.frame(alloc);

        if (ctx.next_scene) |next_scene| {
            cur_scene.deinit(alloc);

            cur_scene = switch (next_scene) {
                .selector => .{ .selector = try .init(alloc, &ctx) },
                .editor => |mod_key| .{ .editor = try .init(alloc, &ctx, mod_key) },
            };
        }
    }

    try globals.saveCustomModules(alloc);
}

test {
    std.testing.refAllDecls(@This());
}
