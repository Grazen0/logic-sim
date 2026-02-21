const std = @import("std");
const rl = @import("raylib");
const rg = @import("raygui");
const structs = @import("./structs/structs.zig");
const scenes = @import("./scenes/scenes.zig");
const consts = @import("./consts.zig");
const globals = @import("./globals.zig");
const GameContext = @import("./GameContext.zig");

const ArrayList = std.ArrayList;
const SlotMap = structs.SlotMap;

const Scene = union(enum) {
    selector: scenes.Selector,
    editor: scenes.Editor,
};

pub fn main() anyerror!void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    const alloc = if (consts.web_build) std.heap.c_allocator else gpa.allocator();
    defer std.debug.assert(!gpa.detectLeaks());
    rl.setConfigFlags(.{
        .msaa_4x_hint = true,
    });

    rl.initWindow(globals.screen_width, globals.screen_height, "Logic Simulator");
    defer rl.closeWindow();

    rl.setExitKey(.null);
    rg.loadStyle("./resources/kanagawa.rgs");
    rl.setTargetFPS(60);

    var ctx: GameContext = .init();
    defer ctx.deinit(alloc);

    var cur_scene: Scene = .{ .selector = try .init(alloc, &ctx) };

    while (!rl.windowShouldClose()) {
        rl.beginDrawing();
        defer rl.endDrawing();

        ctx.next_scene = null;

        switch (cur_scene) {
            .selector => |*sel| try sel.frame(alloc),
            .editor => |*ed| try ed.frame(alloc),
        }

        if (ctx.next_scene) |next_scene| {
            switch (cur_scene) {
                .selector => |*sel| sel.deinit(alloc),
                .editor => |*ed| ed.deinit(alloc),
            }

            cur_scene = switch (next_scene) {
                .selector => .{ .selector = try .init(alloc, &ctx) },
                .editor => |mod_key| .{ .editor = try .init(alloc, &ctx, mod_key) },
            };
        }
    }
}
