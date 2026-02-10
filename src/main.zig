const std = @import("std");
const rl = @import("raylib");
const rg = @import("raygui");
const structs = @import("./structs/structs.zig");
const scenes = @import("./scenes/scenes.zig");
const globals = @import("globals.zig");
const Module = @import("./Module.zig");
const GameContext = @import("./GameContext.zig");

const ArrayList = std.ArrayList;
const SlotMap = structs.SlotMap;

fn andFunc(input: *const ArrayList(bool), output: *ArrayList(bool)) void {
    output.items[0] = input.items[0] and input.items[1];
}

fn orFunc(input: *const ArrayList(bool), output: *ArrayList(bool)) void {
    output.items[0] = input.items[0] or input.items[1];
}

fn xorFunc(input: *const ArrayList(bool), output: *ArrayList(bool)) void {
    output.items[0] = input.items[0] ^ input.items[1];
}

fn norFunc(input: *const ArrayList(bool), output: *ArrayList(bool)) void {
    output.items[0] = !(input.items[0] or input.items[1]);
}

fn notFunc(input: *const ArrayList(bool), output: *ArrayList(bool)) void {
    output.items[0] = !input.items[0];
}

const Scene = union(enum) {
    selector: scenes.Selector,
    editor: scenes.Editor,
};

pub fn main() anyerror!void {
    const alloc = std.heap.c_allocator;
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

    _ = try ctx.modules.put(alloc, .{
        .name = try alloc.dupeZ(u8, "and"),
        .input_cnt = 2,
        .output_cnt = 1,
        .color = .init(0x7E, 0x9C, 0xD8, 0xFF), // blue
        .body = .{ .primitive = andFunc },
    });
    _ = try ctx.modules.put(alloc, .{
        .name = try alloc.dupeZ(u8, "or"),
        .input_cnt = 2,
        .output_cnt = 1,
        .color = .init(0x76, 0x94, 0x6A, 0xFF), // green
        .body = .{ .primitive = orFunc },
    });
    _ = try ctx.modules.put(alloc, .{
        .name = try alloc.dupeZ(u8, "not"),
        .input_cnt = 1,
        .output_cnt = 1,
        .color = .init(0xC3, 0x40, 0x43, 0xFF), // red
        .body = .{ .primitive = notFunc },
    });
    _ = try ctx.modules.put(alloc, .{
        .name = try alloc.dupeZ(u8, "nor"),
        .input_cnt = 2,
        .output_cnt = 1,
        .color = .init(0x95, 0x7F, 0xB8, 0xFF), // purple
        .body = .{ .primitive = norFunc },
    });

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
