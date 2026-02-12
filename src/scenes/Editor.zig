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

const colors = globals.colors;

const wire_thick = 5;
const port_radius = 12;
const top_port_radius_btn = 20;
const top_port_radius_pin = 12;
const top_port_btn_pin_distance = 45;

const HoverInfo = union(enum) {
    none,
    top_input_btn: usize,
    top_input_pin: usize,
    top_output_pin: usize,
    mod_input: Module.InputKey,
    mod_output: Module.OutputKey,
    module: Module.ChildKey,
};

ctx: *GameContext,
top: ModuleInstance,
mouse_action: ?union(enum) {
    drag_module: struct {
        child_key: Module.ChildKey,
        offset: Vector2,
    },
    wire_from: Module.WireSrc,
    wire_to: Module.WireDest,
},
wire_points: ArrayList(Vector2),
selected_child: ?Module.ChildKey,
panel_view: Rectangle,
panel_scroll: Vector2,
panel_width: f32,

pub fn init(gpa: Allocator, ctx: *GameContext, mod_key: Module.Key) !Self {
    return .{
        .ctx = ctx,
        .top = try .fromModule(gpa, &ctx.modules, mod_key),
        .mouse_action = null,
        .wire_points = .empty,
        .selected_child = null,
        .panel_view = .init(0, 0, 0, 0),
        .panel_scroll = .init(0, 0),
        .panel_width = 0,
    };
}

pub fn deinit(self: *Self, gpa: Allocator) void {
    self.top.deinit(gpa);
    self.wire_points.deinit(gpa);
    self.* = undefined;
}

pub fn frame(self: *Self, gpa: Allocator) !void {
    const top_mod = self.ctx.modules.get(self.top.mod_key).?;

    const mouse = rl.getMousePosition();
    const hover = self.getHoverInfo(mouse);

    switch (hover) {
        .none => rl.setMouseCursor(.default),
        else => rl.setMouseCursor(.pointing_hand),
    }

    if (rl.isMouseButtonPressed(.left)) {
        try self.onClick(gpa, hover, mouse);
    } else if (rl.isMouseButtonReleased(.left)) {
        self.onUnclick();
    }

    if (rl.isMouseButtonPressed(.right))
        self.onRightClick();

    if (rl.isKeyPressed(globals.escape_key)) {
        self.ctx.next_scene = .selector;
        return;
    }

    if (rl.isKeyPressed(.delete)) {
        if (self.selected_child) |child_key| {
            try self.removeChild(child_key);
        }
    }

    if (self.mouse_action) |drag| {
        switch (drag) {
            .drag_module => |mod_drag| {
                const dragged_child = top_mod.body.custom.children.get(mod_drag.child_key).?;
                dragged_child.pos = mouse.add(mod_drag.offset);
            },
            else => {},
        }
    }

    rl.clearBackground(colors.background);
    try self.drawSimulation(mouse, hover);
    try self.drawBottomPanel(gpa);
}

fn removeWire(self: *Self, wire_key: Module.WireKey) !void {
    const top_mod = self.ctx.modules.get(self.top.mod_key).?;
    const wire = top_mod.body.custom.wires.get(wire_key).?;
    try self.top.writeWireDest(wire.to, false);

    _ = top_mod.body.custom.wires.remove(wire_key);
}

fn removeChild(self: *Self, child_key: Module.ChildKey) !void {
    const top_mod = self.ctx.modules.get(self.top.mod_key).?;
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

fn drawBottomPanel(self: *Self, gpa: Allocator) !void {
    const btn_spacing = 5;

    const panel_height = 60;
    const panel_rect: Rectangle = .init(
        0,
        globals.screen_height - panel_height,
        globals.screen_width,
        panel_height,
    );
    const panel_contents: Rectangle = .init(0, 0, self.panel_width, panel_rect.height - 20);
    const panel_base = Vector2
        .init(panel_rect.x, panel_rect.y)
        .add(.init(panel_contents.x, panel_contents.y));

    _ = rg.scrollPanel(panel_rect, null, panel_contents, &self.panel_scroll, &self.panel_view);

    rl.beginScissorMode(
        @intFromFloat(self.panel_view.x),
        @intFromFloat(self.panel_view.y),
        @intFromFloat(self.panel_view.width),
        @intFromFloat(self.panel_view.height),
    );
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
            const top_mod = self.ctx.modules.get(self.top.mod_key).?;
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

            self.selected_child = child_key;
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

fn drawWire(self: *const Self, wire: *const Module.Wire) void {
    const top_mod = self.ctx.modules.get(self.top.mod_key).?;

    const wire_value = self.top.readWireSrc(wire.from).?;
    const from_pos = getWireSrcPos(&self.ctx.modules, top_mod, &wire.from);
    const to_pos = getWireDestPos(&self.ctx.modules, top_mod, &wire.to);

    drawWireLines(from_pos, to_pos, wire.points.items, wire_value);
}

fn drawWireLines(start: Vector2, end: Vector2, points: []Vector2, value: bool) void {
    const color = logicColor(value);
    var s = start;

    for (points) |p| {
        rl.drawLineEx(s, p, wire_thick, color);
        rl.drawCircleV(s, wire_thick / 2, color);
        s = p;
    }

    rl.drawLineEx(s, end, wire_thick, color);
    rl.drawCircleV(s, wire_thick / 2, color);
}

fn drawSimulation(self: *Self, mouse: Vector2, hover: HoverInfo) !void {
    const top_mod = self.ctx.modules.get(self.top.mod_key).?;

    var wire_iter = top_mod.body.custom.wires.iterator();
    while (wire_iter.nextValue()) |wire|
        self.drawWire(wire);

    if (self.mouse_action) |drag| {
        switch (drag) {
            .wire_from => |from| {
                const from_value = self.top.readWireSrc(from).?;
                const from_pos = getWireSrcPos(&self.ctx.modules, top_mod, &from);
                drawWireLines(from_pos, mouse, self.wire_points.items, from_value);
            },
            .wire_to => |to| {
                const to_pos = getWireDestPos(&self.ctx.modules, top_mod, &to);
                drawWireLines(to_pos, mouse, self.wire_points.items, false);
            },
            else => {},
        }
    }

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

    var child_iter = top_mod.body.custom.children.iterator();
    while (child_iter.nextKey()) |child_key|
        try self.drawChild(child_key, hover);
}

fn drawChild(self: *const Self, child_key: Module.ChildKey, hover: HoverInfo) !void {
    const top_mod = self.ctx.modules.get(self.top.mod_key).?;
    const child = top_mod.body.custom.children.get(child_key).?;
    const mod = self.ctx.modules.get(child.mod_key).?;

    const size: Vector2 = moduleSize(mod);

    if (self.selected_child) |selected_child| {
        if (selected_child.equals(child_key)) {
            const sel_pad = 8;

            rl.drawRectangleV(
                child.pos.subtractValue(sel_pad),
                size.addValue(2 * sel_pad),
                colors.background_dark.alpha(0.75),
            );
        }
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

fn onClick(self: *Self, gpa: Allocator, hover: HoverInfo, mouse: Vector2) !void {
    const top_mod = self.ctx.modules.get(self.top.mod_key).?;

    if (self.mouse_action) |drag| {
        const new_wire: ?Module.Wire = switch (drag) {
            .drag_module => null,
            .wire_from => |from| switch (hover) {
                .mod_input => |info| .init(from, .{ .mod_input = info }, try self.wire_points.clone(gpa)),
                .top_output_pin => |idx| .init(from, .{ .top_output = idx }, try self.wire_points.clone(gpa)),
                else => null,
            },
            .wire_to => |to| blk: {
                const points_rev = try self.wire_points.clone(gpa);
                std.mem.reverse(Vector2, points_rev.items);

                break :blk switch (hover) {
                    .mod_output => |info| .init(.{ .mod_output = info }, to, points_rev),
                    .top_input_pin => |idx| .init(.{ .top_input = idx }, to, points_rev),
                    else => null,
                };
            },
        };

        if (new_wire) |new_wire_v| {
            try top_mod.body.custom.addWire(gpa, new_wire_v);
            try self.top.propagateLogic(gpa, &self.ctx.modules, new_wire_v.from);
            self.mouse_action = null;
        } else {
            try self.wire_points.append(gpa, mouse);
        }
        return;
    }

    self.selected_child = null;

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
            self.selected_child = child_key;

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
    }
}

fn onRightClick(self: *Self) void {
    if (self.mouse_action) |drag| {
        switch (drag) {
            .wire_from, .wire_to => self.mouse_action = null,
            else => {},
        }
    }
}

fn onUnclick(self: *Self) void {
    if (self.mouse_action) |drag| {
        switch (drag) {
            .drag_module => self.mouse_action = null,
            else => {},
        }
    }
}

fn getHoverInfo(self: *const Self, mouse: Vector2) HoverInfo {
    const top_mod = self.ctx.modules.get(self.top.mod_key).?;

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

    var iter = top_mod.body.custom.children.iterator();

    while (iter.next()) |entry| {
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

fn getWireSrcPos(modules: *const SlotMap(Module), top_mod: *const Module, src: *const Module.WireSrc) Vector2 {
    switch (src.*) {
        .top_input => |i| return topInputPosPin(top_mod.input_cnt, i),
        .mod_output => |*key| {
            const child = top_mod.body.custom.children.get(key.child_key).?;
            const child_mod = modules.get(child.mod_key).?;
            return modOutputPos(child_mod, child.pos, key.output);
        },
    }
}

fn getWireDestPos(modules: *const SlotMap(Module), top_mod: *const Module, dest: *const Module.WireDest) Vector2 {
    switch (dest.*) {
        .top_output => |i| return topOutputPosPin(top_mod.output_cnt, i),
        .mod_input => |info| {
            const child = top_mod.body.custom.children.get(info.child_key).?;
            const child_mod = modules.get(child.mod_key).?;
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
