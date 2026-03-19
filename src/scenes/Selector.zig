const Self = @This();

const std = @import("std");
const rl = @import("raylib");
const rg = @import("raygui");
const re = @import("../ray_extra.zig");
const consts = @import("../consts.zig");
const structs = @import("../structs/structs.zig");
const globals = @import("../globals.zig");
const theme = @import("../theme.zig");
const GameContext = @import("../GameContext.zig");
const core = @import("../core.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Rectangle = rl.Rectangle;
const Vector2 = rl.Vector2;
const IconName = rg.IconName;
const CustomModule = core.CustomModule;
const SlotMap = structs.SlotMap;

const comptimePrint = std.fmt.comptimePrint;

const page_rows = 2;
const page_cols = 6;
const page_size = page_rows * page_cols;

ctx: *GameContext,
mod_list: ArrayList(struct { CustomModule.Key, *const CustomModule }),
page: usize,
max_page: usize,
new_mod_dialog: bool,
new_mod_name_buf: [consts.max_mod_name_size]u8,

extern fn emscripten_run_script(script: [*:0]const u8) void;

pub fn init(gpa: Allocator, ctx: *GameContext) !Self {
    var out: Self = .{
        .ctx = ctx,
        .mod_list = .empty,
        .max_page = undefined,
        .page = 0,
        .new_mod_dialog = false,
        .new_mod_name_buf = undefined,
    };

    try out.computeModList(gpa);
    return out;
}

pub fn deinit(self: *Self, gpa: Allocator) void {
    self.mod_list.deinit(gpa);
    self.* = undefined;
}

pub fn frame(self: *Self, gpa: Allocator) !void {
    const btn_size = 120;
    const btn_spacing = 20;
    const nav_btn_size: Vector2 = .init(50, ((btn_size + btn_spacing) * page_rows) - btn_spacing);

    rl.clearBackground(theme.background);

    const font = rl.getFontDefault() catch unreachable;
    re.drawTextAligned(font, "Logic Simulator", .init(consts.screen_width / 2, 80), 60, 60 * 0.1, theme.text, .center, .top);
    re.drawTextAligned(font, consts.version_string, consts.screen_size.subtract(.init(20, 10)), 30, 30 * 0.1, theme.text_muted, .right, .bottom);

    if (self.new_mod_dialog)
        rg.lock();

    const left_nav_pos: Rectangle = .init(10, (consts.screen_height / 2) - (nav_btn_size.y / 2), nav_btn_size.x, nav_btn_size.y);
    const right_nav_pos: Rectangle = .init(consts.screen_width - nav_btn_size.x - 10, (consts.screen_height / 2) - (nav_btn_size.y / 2), nav_btn_size.x, nav_btn_size.y);

    if (self.page > 0 and rg.button(left_nav_pos, comptimePrint("#{d}#", .{IconName.arrow_left_fill})))
        self.page -= 1;

    if (self.page < self.max_page and rg.button(right_nav_pos, comptimePrint("#{d}#", .{IconName.arrow_right_fill})))
        self.page += 1;

    rg.enable();

    const grid_width = page_cols * (btn_size + btn_spacing) - btn_spacing;
    const gridX = (consts.screen_width / 2) - (grid_width / 2);
    const gridY = left_nav_pos.y;

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
                self.new_mod_name_buf[0] = 0;
                self.new_mod_dialog = true;
            }
        }
    }

    if (self.mod_list.items.len == 0) {
        re.drawTextAligned(
            font,
            "¡Create a new module to begin!",
            .init(consts.screen_width / 2, consts.screen_height - 140),
            consts.font_size,
            consts.font_spacing,
            theme.text_muted,
            .center,
            .bottom,
        );
    }

    rg.enable();

    if (self.new_mod_dialog) {
        rg.unlock();
        rl.drawRectangle(0, 0, consts.screen_width, consts.screen_height, theme.dim);

        const prompt_size: Vector2 = .init(500, 200);
        const prompt_pos = consts.screen_size.subtract(prompt_size).scale(0.5);

        const prompt_result = rg.textInputBox(
            .init(prompt_pos.x, prompt_pos.y, prompt_size.x, prompt_size.y),
            "New module",
            "Module name:",
            "Create",
            @ptrCast(&self.new_mod_name_buf),
            consts.max_mod_name_size,
            null,
        );

        switch (prompt_result) {
            -1 => {},
            0 => self.new_mod_dialog = false,
            1 => try self.confirmCreateModule(gpa),
            else => @panic("invalid prompt result"),
        }

        if (rl.isKeyPressed(consts.escape_key))
            self.new_mod_dialog = false;

        if (rl.isKeyPressed(.enter))
            try self.confirmCreateModule(gpa);
    }

    if (consts.web_build)
        self.drawWebButtons(gpa);
}

var file_gpa: Allocator = undefined;
var file_self: *Self = undefined;

export fn processFile(data_ptr: [*]const u8, data_len: usize) void {
    const data = data_ptr[0..data_len];

    globals.loadCustomModulesFromStr(file_gpa, data) catch |e| {
        std.log.err("Could not load modules file: {}\n", .{e});
        return;
    };

    globals.saveCustomModules(file_gpa) catch unreachable;
    file_self.computeModList(file_gpa) catch unreachable;
}

fn drawWebButtons(self: *Self, gpa: Allocator) void {
    const btn_size: Vector2 = .init(320, 45);

    const pos_1: Vector2 = .init(consts.screen_width / 2, consts.screen_height - 150);
    const pos_2: Vector2 = .init(pos_1.x, pos_1.y + btn_size.y + 20);

    if (globals.modules.count > 0 and rg.button(re.rectWithCenter(pos_1, btn_size), comptimePrint("#{d}# Save modules file", .{IconName.file_save})))
        emscripten_run_script("downloadModulesFile()");

    if (rg.button(re.rectWithCenter(pos_2, btn_size), comptimePrint("#{d}# Load modules file", .{IconName.file_open}))) {
        file_gpa = gpa;
        file_self = self;
        emscripten_run_script("selectModulesFile()");
    }
}

fn confirmCreateModule(self: *Self, gpa: Allocator) !void {
    const strlen = std.mem.len(@as([*:0]u8, @ptrCast(self.new_mod_name_buf[0..])));
    const trimmed = std.mem.trim(u8, self.new_mod_name_buf[0..strlen], " ");

    if (trimmed.len == 0)
        return;

    var inputs: SlotMap(CustomModule.Port) = .empty;
    _ = try inputs.put(gpa, .init(1, 0));
    _ = try inputs.put(gpa, .init(1, 1));

    var outputs: SlotMap(CustomModule.Port) = .empty;
    _ = try outputs.put(gpa, .init(1, 0));

    const new_mod: CustomModule = .{
        .name = try gpa.dupeZ(u8, trimmed),
        .color = .red,
        .inputs = inputs,
        .outputs = outputs,
        .children = .empty,
        .wires = .empty,
    };

    const new_mod_key = try globals.modules.put(gpa, new_mod);
    self.ctx.next_scene = .{ .editor = new_mod_key };

    try globals.saveCustomModules(gpa);
}

fn computeModList(self: *Self, gpa: Allocator) !void {
    var iter = globals.modules.iterator();

    self.mod_list.clearRetainingCapacity();
    try self.mod_list.ensureTotalCapacity(gpa, globals.modules.count);

    while (iter.next()) |entry|
        try self.mod_list.append(gpa, .{ entry.key, entry.val });

    self.max_page = self.mod_list.items.len / page_size;
}
