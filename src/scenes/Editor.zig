const Self = @This();

const std = @import("std");
const rl = @import("raylib");
const rg = @import("raygui");
const re = @import("../ray_extra.zig");
const sim = @import("../simulation.zig");
const math = @import("../math.zig");
const structs = @import("../structs/structs.zig");
const globals = @import("../globals.zig");
const Module = @import("../Module.zig");
const GameContext = @import("../GameContext.zig");

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Vector2 = rl.Vector2;
const Rectangle = rl.Rectangle;
const Color = rl.Color;
const Font = rl.Font;
const SlotMap = structs.SlotMap;
const ModuleInstance = sim.ModuleInstance;
const Wire = Module.Wire;
const WireSrc = Module.WireSrc;
const WireDest = Module.WireDest;

const colors = globals.colors;

const wire_thick = 5;
const port_radius = 12;
const top_port_radius_btn = 20;
const top_port_radius_pin = 12;
const top_port_btn_pin_distance = 45;
const sim_rect: Rectangle = .init(
    15,
    60,
    globals.screen_width - 30,
    globals.screen_height - 140,
);

const HoverInfo = union(enum) {
    none,
    top_input_btn: usize,
    top_input_pin: usize,
    top_output_pin: usize,
    mod_input: Module.InputKey,
    mod_output: Module.OutputKey,
    module: Module.ChildKey,
    wire: Module.WireKey,
};

const SettingsState = struct {
    name: [globals.max_mod_name_size:0]u8,
    name_edit_mode: bool,
    color: Color,
};

ctx: *GameContext,
top: ModuleInstance,
mouse_action: union(enum) {
    none,
    drag_module: struct {
        child_key: Module.ChildKey,
        offset: Vector2,
    },
    wire_from: WireSrc,
    wire_to: WireDest,
},
wire_points: ArrayList(Vector2),
selection: union(enum) {
    none,
    wire: Module.WireKey,
    child: Module.ChildKey,
},
panel_view: Rectangle,
panel_scroll: Vector2,
panel_width: f32,
settings: ?SettingsState,

pub fn init(gpa: Allocator, ctx: *GameContext, mod_key: Module.Key) !Self {
    return .{
        .ctx = ctx,
        .top = try .fromModule(gpa, &ctx.modules, mod_key),
        .mouse_action = .none,
        .wire_points = .empty,
        .selection = .none,
        .panel_view = .init(0, 0, 0, 0),
        .panel_scroll = .init(0, 0),
        .panel_width = 0,
        .settings = null,
    };
}

pub fn deinit(self: *Self, gpa: Allocator) void {
    self.top.deinit(gpa);
    self.wire_points.deinit(gpa);
    self.* = undefined;
}

pub fn frame(self: *Self, gpa: Allocator) !void {
    rg.unlock();

    if (self.settings != null)
        rg.lock();

    const top_mod = self.topMod();

    const mouse = rl.getMousePosition();
    const hover = self.getHoverInfo(mouse);

    switch (hover) {
        .none => rl.setMouseCursor(.default),
        else => rl.setMouseCursor(.pointing_hand),
    }

    rl.clearBackground(colors.background);
    const snapped_mouse = try self.drawSimulation(mouse, hover);

    if (rl.isMouseButtonPressed(.left)) {
        try self.onClick(gpa, hover, mouse, snapped_mouse);
    } else if (rl.isMouseButtonReleased(.left)) {
        self.onUnclick();
    }

    if (rl.isMouseButtonPressed(.right))
        self.onRightClick();

    if (rl.isKeyPressed(globals.escape_key)) {
        if (self.settings) |*settings| {
            try self.closeSettings(gpa, settings, false);
        } else {
            const dragging_wire = self.mouse_action == .wire_from or self.mouse_action == .wire_to;

            if (dragging_wire) {
                self.mouse_action = .none;
            } else {
                self.ctx.next_scene = .selector;
                return;
            }
        }
    }

    if (rl.isKeyPressed(.delete)) {
        switch (self.selection) {
            .child => |child_key| try self.removeChild(child_key),
            .wire => |wire| try self.removeWire(wire),
            .none => {},
        }
    }

    switch (self.mouse_action) {
        .drag_module => |drag| {
            const dragged_child = top_mod.body.custom.children.get(drag.child_key).?;
            const dragged_child_mod = self.ctx.modules.get(dragged_child.mod_key).?;
            const child_size = moduleSize(dragged_child_mod);

            dragged_child.pos = mouse.add(drag.offset).clamp(
                .init(sim_rect.x, sim_rect.y),
                .init(
                    sim_rect.x + sim_rect.width - child_size.x,
                    sim_rect.y + sim_rect.height - child_size.y,
                ),
            );
        },
        else => {},
    }

    self.drawTopBar();
    try self.drawBottomPanel(gpa);

    if (self.settings) |*settings| {
        rg.unlock();
        try self.drawSettingsMenu(gpa, settings);
    }
}

fn removeWire(self: *Self, wire_key: Module.WireKey) !void {
    const top_mod = self.topMod();
    const wire = top_mod.body.custom.wires.get(wire_key).?;
    try self.top.writeWireDest(wire.to, false);

    _ = top_mod.body.custom.wires.remove(wire_key);
}

fn removeChild(self: *Self, child_key: Module.ChildKey) !void {
    const top_mod = self.topMod();
    var wire_iter = top_mod.body.custom.wires.iterator();

    while (wire_iter.next()) |entry| {
        const wire = entry.val;

        const matches_from = switch (wire.from) {
            .top_input => false,
            .mod_output => |info| info.child_key.equals(child_key),
        };

        const matches_to = switch (wire.to) {
            .top_output => false,
            .mod_input => |info| info.child_key.equals(child_key),
        };

        if (matches_from or matches_to)
            try self.removeWire(entry.key);
    }

    _ = top_mod.body.custom.children.remove(child_key);
    _ = self.top.body.custom.remove(child_key);
}

fn drawSettingsMenu(self: *Self, gpa: Allocator, settings: *SettingsState) !void {
    rl.drawRectangle(0, 0, globals.screen_width, globals.screen_height, colors.dim);

    const rect_size: Vector2 = .init(600, 400);
    const rect_pos: Vector2 = globals.screen_size.subtract(rect_size).divide(.init(2, 2));

    const win_rect: Rectangle = .init(rect_pos.x, rect_pos.y, rect_size.x, rect_size.y);
    const result = rg.windowBox(win_rect, "Module settings");

    if (result == 1) {
        try self.closeSettings(gpa, settings, false);
        return;
    }

    const pad = 30;
    const font = try rl.getFontDefault();

    rl.drawTextEx(font, "Name:", .init(win_rect.x + pad, win_rect.y + 45), 24, 24 * 0.1, colors.text);

    const mod_name_rect: Rectangle = .init(
        win_rect.x + pad,
        win_rect.y + 80,
        win_rect.width - (2 * pad),
        40,
    );

    if (rg.textBox(mod_name_rect, &settings.name, 30, settings.name_edit_mode))
        settings.name_edit_mode = !settings.name_edit_mode;

    rl.drawText(
        "Color:",
        @as(i32, @intFromFloat(win_rect.x)) + pad,
        @as(i32, @intFromFloat(win_rect.y)) + 150,
        24,
        colors.text,
    );

    const color_demo_rect: Rectangle = .init(win_rect.x + pad + 80, win_rect.y + 150, 24, 24);
    rl.drawRectangleRec(color_demo_rect, settings.color);
    rl.drawRectangleLinesEx(color_demo_rect, 1, colors.text_muted);

    _ = rg.colorPicker(
        .init(win_rect.x + pad, win_rect.y + 185, win_rect.width - (2 * pad) - 20, 120),
        "Color",
        &settings.color,
    );

    const save_btn_rect: Rectangle = .init(
        win_rect.x + pad,
        win_rect.y + win_rect.height - 50,
        win_rect.width - (2 * pad),
        30,
    );

    if (rg.button(save_btn_rect, "Save") or rl.isKeyPressed(.enter))
        try self.closeSettings(gpa, settings, true);
}

fn openSettings(self: *Self) void {
    const top_mod = self.topMod();

    self.settings = .{
        .name = undefined,
        .name_edit_mode = true,
        .color = top_mod.color,
    };

    const n = top_mod.name.len + 1;
    @memcpy(self.settings.?.name[0..n], top_mod.name.ptr[0..n]);
}

fn closeSettings(self: *Self, gpa: Allocator, settings: *const SettingsState, save: bool) !void {
    if (save) {
        const top_mod = self.topMod();

        const strlen = std.mem.len(@as([*:0]const u8, settings.name[0..]));
        const trimmed = std.mem.trim(u8, settings.name[0..strlen], " ");

        if (trimmed.len == 0)
            return;

        top_mod.color = settings.color;
        gpa.free(top_mod.name);
        top_mod.name = try gpa.dupeZ(u8, trimmed);
    }

    self.settings = null;
}

fn drawTopBar(self: *Self) void {
    const top_mod = self.topMod();

    if (rg.button(.init(15, 10, 40, 40), "#114#"))
        self.ctx.next_scene = .selector;

    if (rg.button(.init(65, 10, 40, 40), "#140#"))
        self.openSettings();

    rl.drawText(top_mod.name, 125, 15, globals.font_size, colors.text);
}

fn drawBottomPanel(self: *Self, gpa: Allocator) !void {
    const btn_spacing = 8;

    const panel_height = 65;
    const panel_rect: Rectangle = .init(
        15,
        globals.screen_height - panel_height - 10,
        globals.screen_width - 30,
        panel_height,
    );
    const panel_contents: Rectangle = .init(0, 0, self.panel_width, panel_rect.height - 10);
    const panel_base = Vector2
        .init(panel_rect.x, panel_rect.y)
        .add(.init(panel_contents.x, panel_contents.y));

    _ = rg.scrollPanel(panel_rect, null, panel_contents, &self.panel_scroll, &self.panel_view);

    rl.drawRectangleLinesEx(panel_rect, 2, colors.text_muted);

    re.beginScissorModeRec(self.panel_view);
    defer rl.endScissorMode();

    var iter = self.ctx.modules.iterator();

    const btn_height = panel_contents.height - (2 * btn_spacing);
    var btn_x = panel_base.x + btn_spacing;

    while (iter.next()) |entry| {
        const mod = entry.val;
        const btn_width = 20 + @as(f32, @floatFromInt(rl.measureText(mod.name, globals.font_size)));

        const btn_pos_abs: Vector2 = .init(btn_x, panel_base.y + btn_spacing);

        btn_x += btn_width + (2 * btn_spacing);
        const btn_pos_rel = btn_pos_abs.add(self.panel_scroll);

        re.guiSetEnabled(!Module.dependsOn(&self.ctx.modules, entry.key, self.top.mod_key));
        const pressed = rg.button(.init(btn_pos_rel.x, btn_pos_rel.y, btn_width, btn_height), mod.name);
        rg.enable();

        if (pressed) {
            const top_mod = self.topMod();
            var child_pos: Vector2 = globals.screen_size
                .subtract(moduleSize(entry.val))
                .divide(.init(2, 2));

            while (containsChildWithPos(&top_mod.body.custom.children, child_pos)) {
                child_pos = child_pos.addValue(20);
            }

            const child_key = try top_mod.body.custom.children.put(gpa, .{
                .pos = child_pos,
                .mod_key = entry.key,
            });

            _ = try self.top.body.custom.put(
                gpa,
                child_key,
                try ModuleInstance.fromModule(gpa, &self.ctx.modules, entry.key),
            );

            self.selection = .{ .child = child_key };
        }
    }

    self.panel_width = btn_x;
}

fn containsChildWithPos(children: *const SlotMap(Module.Child), pos: Vector2) bool {
    var iter = children.const_iterator();

    while (iter.nextValue()) |child| {
        if (child.pos.distanceSqr(pos) < std.math.pow(f32, globals.epsilon, 2))
            return true;
    }

    return false;
}

fn drawWire(self: *const Self, wire: *const Wire, highlight: bool) void {
    const wire_value = self.top.readWireSrc(wire.from).?;
    const from_pos = self.getWireSrcPos(&wire.from);
    const to_pos = self.getWireDestPos(&wire.to);

    if (highlight)
        drawWireLines(
            from_pos,
            to_pos,
            wire.points.items,
            3 * wire_thick,
            Color.black.alpha(0.5),
        );

    drawWireLines(from_pos, to_pos, wire.points.items, wire_thick, logicColor(wire_value));
}

fn drawWireLines(start: Vector2, end: Vector2, points: []Vector2, thick: f32, color: Color) void {
    var s = start;

    for (points) |p| {
        rl.drawLineEx(s, p, thick, color);
        rl.drawCircleV(s, thick / 2, color);
        s = p;
    }

    rl.drawLineEx(s, end, thick, color);
    rl.drawCircleV(s, thick / 2, color);
    rl.drawCircleV(end, thick / 2, color);
}

fn drawSimulation(self: *Self, mouse: Vector2, hover: HoverInfo) !Vector2 {
    rl.drawRectangleLinesEx(sim_rect, 2, colors.text_muted);

    re.beginScissorModeRec(sim_rect);
    defer rl.endScissorMode();

    const top_mod = self.topMod();

    var wire_iter = top_mod.body.custom.wires.iterator();
    while (wire_iter.next()) |entry| {
        const highlight = switch (self.selection) {
            .wire => |wire_key| wire_key.equals(entry.key),
            else => false,
        };
        self.drawWire(entry.val, highlight);
    }

    const snap = rl.isKeyDown(.left_shift);

    const snapped_mouse: Vector2 = switch (self.mouse_action) {
        .wire_from => |from| blk: {
            const from_value = self.top.readWireSrc(from).?;
            const from_pos = self.getWireSrcPos(&from);

            const last_point = self.wire_points.getLastOrNull() orelse from_pos;
            const snapped_mouse = if (snap) math.snap(last_point, mouse) else mouse;

            drawWireLines(from_pos, snapped_mouse, self.wire_points.items, wire_thick, logicColor(from_value));
            break :blk snapped_mouse;
        },
        .wire_to => |to| blk: {
            const to_pos = self.getWireDestPos(&to);
            const last_point = self.wire_points.getLastOrNull() orelse to_pos;
            const snapped_mouse = if (snap) math.snap(last_point, mouse) else mouse;
            drawWireLines(to_pos, snapped_mouse, self.wire_points.items, wire_thick, logicColor(false));
            break :blk snapped_mouse;
        },
        else => .init(0, 0),
    };

    for (0..top_mod.input_cnt) |input| {
        const value = self.top.inputs.items[input];
        const btn_pos = topInputPosBtn(top_mod.input_cnt, input);
        const pin_pos = topInputPosPin(top_mod.input_cnt, input);

        const highlight = switch (hover) {
            .top_input_pin => |i| i == input,
            else => false,
        };

        rl.drawLineEx(btn_pos, pin_pos, 8, colors.port);
        rl.drawCircleV(pin_pos, top_port_radius_pin, if (highlight) colors.background_alt else colors.port);
        rl.drawCircleV(btn_pos, top_port_radius_btn, logicColor(value));
    }

    for (0..top_mod.output_cnt) |output| {
        const value = self.top.outputs.items[output];
        const btn_pos = topOutputPosBtn(top_mod.output_cnt, output);
        const pin_pos = topOutputPosPin(top_mod.output_cnt, output);

        const highlight = switch (hover) {
            .top_output_pin => |i| i == output,
            else => false,
        };

        rl.drawLineEx(btn_pos, pin_pos, 8, colors.port);
        rl.drawCircleV(pin_pos, top_port_radius_pin, if (highlight) colors.background_alt else colors.port);
        rl.drawCircleV(btn_pos, top_port_radius_btn, logicColor(value));
    }

    var child_iter = top_mod.body.custom.children.rev_iterator();
    while (child_iter.nextKey()) |child_key|
        try self.drawChild(child_key, hover);

    return snapped_mouse;
}

fn drawChild(self: *const Self, child_key: Module.ChildKey, hover: HoverInfo) !void {
    const top_mod = self.topMod();
    const child = top_mod.body.custom.children.get(child_key).?;
    const mod = self.ctx.modules.get(child.mod_key).?;

    const size: Vector2 = moduleSize(mod);

    switch (self.selection) {
        .child => |selected_child| if (selected_child.equals(child_key)) {
            const sel_pad = 8;

            rl.drawRectangleV(
                child.pos.subtractValue(sel_pad),
                size.addValue(2 * sel_pad),
                Color.black.alpha(0.5),
            );
        },
        else => {},
    }

    rl.drawRectangleV(child.pos, size, mod.color);

    for (0..mod.input_cnt) |input| {
        const highlight = switch (hover) {
            .mod_input => |info| info.child_key.equals(child_key) and info.input == input,
            else => false,
        };

        rl.drawCircleV(
            modInputPos(mod, child.pos, input),
            port_radius,
            if (highlight) colors.background_alt else colors.port,
        );
    }

    for (0..mod.output_cnt) |output| {
        const highlight = switch (hover) {
            .mod_output => |info| info.child_key.equals(child_key) and info.output == output,
            else => false,
        };

        rl.drawCircleV(
            modOutputPos(mod, child.pos, output),
            port_radius,
            if (highlight) colors.background_alt else colors.port,
        );
    }

    const font = try rl.getFontDefault();

    re.drawTextAligned(
        font,
        mod.name,
        child.pos.add(size.divide(.init(2, 2))),
        globals.font_size,
        globals.font_spacing,
        colors.text,
        .center,
        .center,
    );
}

fn addWire(self: *Self, gpa: Allocator, wire: Wire) !void {
    const top_mod = self.topMod();

    const new_wire_key = try top_mod.body.custom.addWire(gpa, wire);
    try self.top.propagateLogic(gpa, &self.ctx.modules, wire.from);
    self.mouse_action = .none;
    self.selection = .{ .wire = new_wire_key };
}

fn onClick(self: *Self, gpa: Allocator, hover: HoverInfo, mouse: Vector2, snapped_mouse: Vector2) !void {
    const top_mod = self.topMod();

    switch (self.mouse_action) {
        .wire_from => |from| switch (hover) {
            .mod_input => |info| {
                const new_wire: Wire = .init(from, .{ .mod_input = info }, try self.wire_points.clone(gpa));
                try self.addWire(gpa, new_wire);
            },
            .top_output_pin => |idx| {
                const new_wire: Wire = .init(from, .{ .top_output = idx }, try self.wire_points.clone(gpa));
                try self.addWire(gpa, new_wire);
            },
            else => try self.wire_points.append(gpa, snapped_mouse),
        },
        .wire_to => |to| blk: {
            const points_rev = try self.wire_points.clone(gpa);
            std.mem.reverse(Vector2, points_rev.items);

            break :blk switch (hover) {
                .mod_output => |info| {
                    const new_wire: Wire = .init(.{ .mod_output = info }, to, points_rev);
                    try self.addWire(gpa, new_wire);
                },
                .top_input_pin => |idx| {
                    const new_wire: Wire = .init(.{ .top_input = idx }, to, points_rev);
                    try self.addWire(gpa, new_wire);
                },
                else => try self.wire_points.append(gpa, snapped_mouse),
            };
        },
        .drag_module => {},
        .none => {
            self.selection = .none;

            switch (hover) {
                .none => {},
                .top_input_btn => |input| {
                    self.top.inputs.items[input] = !self.top.inputs.items[input];
                    try self.top.propagateLogic(gpa, &self.ctx.modules, .{ .top_input = input });
                },
                .top_input_pin => |input| {
                    self.mouse_action = .{ .wire_from = .{ .top_input = input } };
                    self.wire_points.clearAndFree(gpa);
                },
                .top_output_pin => |output| {
                    self.mouse_action = .{ .wire_to = .{ .top_output = output } };
                    self.wire_points.clearAndFree(gpa);
                },
                .module => |child_key| {
                    self.selection = .{ .child = child_key };

                    self.mouse_action = .{
                        .drag_module = .{
                            .child_key = child_key,
                            .offset = top_mod.body.custom.children.get(child_key).?.pos.subtract(mouse),
                        },
                    };
                },
                .mod_input => |info| {
                    self.mouse_action = .{ .wire_to = .{ .mod_input = info } };
                    self.wire_points.clearAndFree(gpa);
                },
                .mod_output => |info| {
                    self.mouse_action = .{ .wire_from = .{ .mod_output = info } };
                    self.wire_points.clearAndFree(gpa);
                },
                .wire => |wire| self.selection = .{ .wire = wire },
            }
        },
    }
}

fn onRightClick(self: *Self) void {
    switch (self.mouse_action) {
        .wire_from, .wire_to => self.mouse_action = .none,
        else => {},
    }
}

fn onUnclick(self: *Self) void {
    switch (self.mouse_action) {
        .drag_module => self.mouse_action = .none,
        else => {},
    }
}

fn getHoverInfo(self: *const Self, mouse: Vector2) HoverInfo {
    if (self.settings != null)
        return .none;

    const top_mod = self.topMod();

    for (0..top_mod.input_cnt) |input| {
        if (mouse.distance(topInputPosBtn(top_mod.input_cnt, input)) <= top_port_radius_btn)
            return .{ .top_input_btn = input };

        if (mouse.distance(topInputPosPin(top_mod.input_cnt, input)) <= top_port_radius_pin)
            return .{ .top_input_pin = input };
    }

    for (0..top_mod.output_cnt) |output| {
        if (mouse.distance(topOutputPosPin(top_mod.output_cnt, output)) <= top_port_radius_pin)
            return .{ .top_output_pin = output };
    }

    var child_iter = top_mod.body.custom.children.iterator();

    while (child_iter.next()) |entry| {
        const child = entry.val;
        const child_mod = self.ctx.modules.get(child.mod_key).?;

        for (0..child_mod.input_cnt) |input| {
            const input_pos = modInputPos(child_mod, child.pos, input);

            if (mouse.distance(input_pos) <= port_radius)
                return .{ .mod_input = .{ .child_key = entry.key, .input = input } };
        }

        for (0..child_mod.output_cnt) |output| {
            const output_pos = modOutputPos(child_mod, child.pos, output);

            if (mouse.distance(output_pos) <= port_radius)
                return .{ .mod_output = .{ .child_key = entry.key, .output = output } };
        }

        const child_size = moduleSize(child_mod);
        const rect: Rectangle = .init(child.pos.x, child.pos.y, child_size.x, child_size.y);

        if (math.checkVec2RectCollision(mouse, rect))
            return .{ .module = entry.key };
    }

    var wire_iter = top_mod.body.custom.wires.iterator();

    while (wire_iter.next()) |entry| {
        const wire = entry.val;
        const from_pos = self.getWireSrcPos(&wire.from);
        const to_pos = self.getWireDestPos(&wire.to);

        var s = from_pos;

        for (wire.points.items) |p| {
            if (math.touchesSegment(mouse, s, p, 10))
                return .{ .wire = entry.key };

            s = p;
        }

        if (math.touchesSegment(mouse, s, to_pos, 10))
            return .{ .wire = entry.key };
    }

    return .none;
}

fn modInputPos(module: *const Module, base_pos: Vector2, idx: usize) Vector2 {
    const mod_size = moduleSize(module);
    return .init(
        base_pos.x,
        base_pos.y - port_radius + math.interpolate(module.input_cnt, idx, mod_size.y + (2 * port_radius)),
    );
}

fn modOutputPos(module: *const Module, base_pos: Vector2, idx: usize) Vector2 {
    const mod_size = moduleSize(module);
    return .init(
        base_pos.x + mod_size.x,
        base_pos.y - port_radius + math.interpolate(module.output_cnt, idx, mod_size.y + (2 * port_radius)),
    );
}

fn topInputPosBtn(input_cnt: usize, input: usize) Vector2 {
    return .init(
        2 * top_port_radius_btn,
        math.interpolate(input_cnt, input, globals.screen_height),
    );
}

fn topInputPosPin(input_cnt: usize, input: usize) Vector2 {
    return topInputPosBtn(input_cnt, input).add(.init(top_port_btn_pin_distance, 0));
}

fn topOutputPosBtn(output_cnt: usize, input: usize) Vector2 {
    return .init(
        globals.screen_width - (2 * top_port_radius_btn),
        math.interpolate(output_cnt, input, globals.screen_height),
    );
}

fn topOutputPosPin(input_cnt: usize, input: usize) Vector2 {
    return topOutputPosBtn(input_cnt, input).subtract(.init(top_port_btn_pin_distance, 0));
}

fn getWireSrcPos(self: *const Self, src: *const WireSrc) Vector2 {
    const top_mod = self.topMod();

    switch (src.*) {
        .top_input => |i| return topInputPosPin(top_mod.input_cnt, i),
        .mod_output => |*key| {
            const child = top_mod.body.custom.children.get(key.child_key).?;
            const child_mod = self.ctx.modules.get(child.mod_key).?;
            return modOutputPos(child_mod, child.pos, key.output);
        },
    }
}

fn getWireDestPos(self: *const Self, dest: *const WireDest) Vector2 {
    const top_mod = self.topMod();

    switch (dest.*) {
        .top_output => |i| return topOutputPosPin(top_mod.output_cnt, i),
        .mod_input => |info| {
            const child = top_mod.body.custom.children.get(info.child_key).?;
            const child_mod = self.ctx.modules.get(child.mod_key).?;
            return modInputPos(child_mod, child.pos, info.input);
        },
    }
}

fn logicColor(value: bool) Color {
    return if (value) colors.logic_on else colors.logic_off;
}

fn moduleSize(module: *const Module) Vector2 {
    const ports: f32 = @floatFromInt(@max(module.input_cnt, module.output_cnt));
    const width_extra = 20 * std.math.log2(ports + 1);
    const min_width: f32 = @floatFromInt(rl.measureText(module.name, globals.font_size));
    return .init(10 + min_width + width_extra, (ports * (2 * port_radius)) + ((ports + 1) * 4));
}

fn topMod(self: *const Self) *Module {
    return self.ctx.modules.get(self.top.mod_key).?;
}
