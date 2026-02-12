const Self = @This();

const std = @import("std");
const rl = @import("raylib");
const rg = @import("raygui");
const re = @import("../ray_extra.zig");
const globals = @import("../globals.zig");
const GameContext = @import("../GameContext.zig");
const Module = @import("../Module.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Rectangle = rl.Rectangle;
const Vector2 = rl.Vector2;
const colors = globals.colors;

const btn_size = 120;
const btn_spacing = 20;
const nav_btn_size: Vector2 = .init(50, ((btn_size + btn_spacing) * page_rows) - btn_spacing);

const page_rows = 2;
const page_cols = 6;
const page_size = page_rows * page_cols;

ctx: *GameContext,
mod_list: ArrayList(struct { Module.Key, *const Module }),
page: usize,
max_page: usize,
new_mod_dialog: bool,
new_mod_name: [globals.max_mod_name_size:0]u8,

pub fn init(gpa: Allocator, ctx: *GameContext) !Self {
    var out: Self = .{
        .ctx = ctx,
        .mod_list = .empty,
        .max_page = undefined,
        .page = 0,
        .new_mod_dialog = false,
        .new_mod_name = undefined,
    };

    try out.compute_mod_list(gpa);
    return out;
}

pub fn deinit(self: *Self, gpa: Allocator) void {
    self.mod_list.deinit(gpa);
    self.* = undefined;
}

pub fn frame(self: *Self, gpa: Allocator) !void {
    rl.clearBackground(colors.background);

    const font = try rl.getFontDefault();
    re.drawTextAligned(
        font,
        "Logic Simulator",
        .init(globals.screen_width / 2, 80),
        60,
        60 * 0.1,
        colors.text,
        .center,
        .top,
    );

    if (self.new_mod_dialog)
        rg.lock();

    const leftNavPos: Rectangle = .init(10, (globals.screen_height / 2) - (nav_btn_size.y / 2), nav_btn_size.x, nav_btn_size.y);
    const rightNavPos: Rectangle = .init(globals.screen_width - nav_btn_size.x - 10, (globals.screen_height / 2) - (nav_btn_size.y / 2), nav_btn_size.x, nav_btn_size.y);

    if (self.page > 0 and rg.button(leftNavPos, "#118#"))
        self.page -= 1;

    if (self.page < self.max_page and rg.button(rightNavPos, "#119#"))
        self.page += 1;

    rg.enable();

    const gridWidth = page_cols * (btn_size + btn_spacing) - btn_spacing;
    const gridX = (globals.screen_width / 2) - (gridWidth / 2);
    const gridY = leftNavPos.y;

    for (0..page_size) |pi| {
        const idx = (self.page * page_size) + pi;
        const mod = if (idx < self.mod_list.items.len) self.mod_list.items[idx] else null;
        const row: f32 = @floatFromInt(pi / page_cols);
        const col: f32 = @floatFromInt(pi % page_cols);

        const is_add_btn = idx == self.mod_list.items.len;
        re.guiSetEnabled(mod != null or is_add_btn);

        const pressed = rg.button(
            .init(
                gridX + ((btn_size + btn_spacing) * col),
                gridY + ((btn_size + btn_spacing) * row),
                btn_size,
                btn_size,
            ),
            if (mod) |m| m[1].name else if (is_add_btn) "+" else "",
        );

        if (pressed) {
            if (mod) |m| {
                self.ctx.next_scene = .{ .editor = m[0] };
            } else { // implies is_add_btn
                self.new_mod_name[0] = 0;
                self.new_mod_dialog = true;
            }
        }
    }

    if (self.mod_list.items.len == 0) {
        re.drawTextAligned(
            font,
            "¡Create a new module to begin!",
            .init(globals.screen_width / 2, globals.screen_height - 100),
            globals.font_size,
            globals.font_spacing,
            colors.text_muted,
            .center,
            .bottom,
        );
    }

    rg.enable();

    if (self.new_mod_dialog) {
        rg.unlock();
        rl.drawRectangle(0, 0, globals.screen_width, globals.screen_height, colors.dim);

        const promptSize: Vector2 = .init(500, 200);
        const promptPos = globals.screen_size.subtract(promptSize).divide(.init(2, 2));

        const prompt_result = rg.textInputBox(
            .init(promptPos.x, promptPos.y, promptSize.x, promptSize.y),
            "New module",
            "Module name:",
            "Create",
            &self.new_mod_name,
            globals.max_mod_name_size,
            null,
        );

        switch (prompt_result) {
            -1 => {},
            0 => self.new_mod_dialog = false,
            1 => try self.confirm_create_module(gpa),
            else => @panic("invalid prompt result"),
        }

        if (rl.isKeyPressed(globals.escape_key))
            self.new_mod_dialog = false;

        if (rl.isKeyPressed(.enter))
            try self.confirm_create_module(gpa);
    }
}

fn confirm_create_module(self: *Self, gpa: Allocator) !void {
    const strlen = std.mem.len(@as([*:0]u8, self.new_mod_name[0..]));
    const trimmed = std.mem.trim(u8, self.new_mod_name[0..strlen], " ");

    if (trimmed.len == 0)
        return;

    const new_mod: Module = .{
        .name = try gpa.dupeZ(u8, trimmed),
        .body = .{
            .custom = .{
                .children = .empty,
                .wires = .empty,
            },
        },
        .color = .red,
        .input_cnt = 4,
        .output_cnt = 4,
    };

    const new_mod_key = try self.ctx.modules.put(gpa, new_mod);
    self.ctx.next_scene = .{ .editor = new_mod_key };
}

fn compute_mod_list(self: *Self, gpa: Allocator) !void {
    var iter = self.ctx.modules.iterator();

    self.mod_list.clearAndFree(gpa);

    while (iter.next()) |entry| {
        switch (entry.val.body) {
            .primitive => {},
            .custom => try self.mod_list.append(gpa, .{ entry.key, entry.val }),
        }
    }

    self.max_page = self.mod_list.items.len / page_size;
}
