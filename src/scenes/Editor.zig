const Self = @This();

const std = @import("std");
const rl = @import("raylib");
const rg = @import("raygui");
const re = @import("../ray_extra.zig");
const sim = @import("../simulation.zig");
const math = @import("../math.zig");
const structs = @import("../structs/structs.zig");
const consts = @import("../consts.zig");
const theme = @import("../theme.zig");
const globals = @import("../globals.zig");
const core = @import("../core.zig");
const GameContext = @import("../GameContext.zig");

const AutoHashMap = std.AutoHashMap;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Vector2 = rl.Vector2;
const Rectangle = rl.Rectangle;
const Color = rl.Color;
const Font = rl.Font;
const IconName = rg.IconName;
const SlotMap = structs.SlotMap;
const ModuleInstance = sim.ModuleInstance;
const CustomModuleInstance = sim.CustomModuleInstance;
const Module = core.Module;
const CustomModule = core.CustomModule;
const Child = CustomModule.Child;
const Wire = CustomModule.Wire;
const WireSrc = CustomModule.WireSrc;
const WireDest = CustomModule.WireDest;

const assert = std.debug.assert;
const comptimePrint = std.fmt.comptimePrint;

const wire_thick = 5;
const port_radius = 12;
const top_port_radius_btn = 20;
const top_port_radius_pin = 12;
const top_port_btn_pin_distance = 45;
const sim_rect: Rectangle = .init(
    15,
    60,
    consts.screen_width - 30,
    consts.screen_height - 140,
);

const HoverInfo = union(enum) {
    none,
    top_input_btn: CustomModule.InputKey,
    top_input_pin: CustomModule.InputKey,
    top_output_pin: CustomModule.OutputKey,
    child_input: CustomModule.ChildInput,
    child_output: CustomModule.ChildOutput,
    child: Child.Key,
    wire: CustomModule.WireKey,

    pub fn isChildInput(self: *const @This(), child_key: Child.Key) bool {
        return self == .mod_input and self.child_input.child_key.equals(child_key);
    }

    pub fn isChildOutput(self: *const @This(), child_key: Child.Key) bool {
        return self == .mod_output and self.child_output.child_key.equals(child_key);
    }
};

const ModuleSettings = struct {
    name: [consts.max_mod_name_size:0]u8,
    name_edit_mode: bool,
    color: Color,
};

ctx: *GameContext,
top_inst: CustomModuleInstance,
disabled_modules: AutoHashMap(CustomModule.Key, void),
mouse_action: union(enum) {
    none,
    drag_module: struct {
        child_key: Child.Key,
        offset: Vector2,
    },
    wire_from: WireSrc,
    wire_to: WireDest,
},
wire_points: ArrayList(Vector2),
selection: union(enum) {
    none,
    wire: CustomModule.WireKey,
    child: Child.Key,
},
panel_view: Rectangle,
panel_scroll: Vector2,
panel_contents_width: f32,
mod_settings: ?ModuleSettings,
child_settings: ?struct {
    child_key: Child.Key,
    v: Module.Settings,
},

pub fn init(gpa: Allocator, ctx: *GameContext, mod_key: CustomModule.Key) !Self {
    var out: Self = .{
        .ctx = ctx,
        .top_inst = try .fromModuleNoUpdate(gpa, mod_key),
        .disabled_modules = .init(gpa),
        .mouse_action = .none,
        .wire_points = .empty,
        .selection = .none,
        .panel_view = .init(0, 0, 0, 0),
        .panel_scroll = .init(0, 0),
        .panel_contents_width = 0,
        .mod_settings = null,
        .child_settings = null,
    };

    try out.top_inst.update(gpa);

    var mod_iter = globals.modules.const_iterator();
    while (mod_iter.nextKey()) |key| {
        if (CustomModule.dependsOn(key, mod_key))
            try out.disabled_modules.put(key, {});
    }

    return out;
}

pub fn deinit(self: *Self, gpa: Allocator) void {
    self.top_inst.deinit(gpa);
    self.wire_points.deinit(gpa);
    self.disabled_modules.deinit();
    self.* = undefined;
}

pub fn frame(self: *Self, gpa: Allocator) !void {
    rg.unlock();

    if (self.mod_settings != null or self.child_settings != null)
        rg.lock();

    const top_mod = self.topMod();

    const mouse = rl.getMousePosition();
    const hover = self.getHoverInfo(mouse);

    switch (hover) {
        .none => rl.setMouseCursor(.default),
        else => rl.setMouseCursor(.pointing_hand),
    }

    rl.clearBackground(theme.background);
    try self.drawSimulation(gpa, mouse, hover);

    if (rl.isMouseButtonPressed(.left)) {
        try self.onClick(gpa, hover, mouse);
    } else if (rl.isMouseButtonReleased(.left)) {
        try self.onUnclick(gpa);
    }

    if (rl.isMouseButtonPressed(.right))
        self.onRightClick();

    if (rl.isKeyPressed(consts.escape_key)) {
        if (self.mod_settings) |*settings| {
            try self.closeModSettings(gpa, settings, false);
        } else if (self.child_settings) |*settings| {
            try self.closeChildSettings(gpa, settings.child_key, &settings.v, false);
        } else if (self.mouse_action == .wire_from or self.mouse_action == .wire_to) {
            self.mouse_action = .none;
        } else if (self.selection != .none) {
            self.selection = .none;
        } else {
            self.ctx.next_scene = .{ .selector = .{ .delete_mod = null } };
            return;
        }
    }

    if (rl.isKeyPressed(.delete)) {
        switch (self.selection) {
            .child => |child_key| try self.removeChild(gpa, child_key),
            .wire => |wire_key| try self.removeWire(gpa, wire_key),
            .none => {},
        }
    }

    switch (self.mouse_action) {
        .drag_module => |drag| {
            const dragged_child = top_mod.children.get(drag.child_key).?;
            const clamp_bounds = childClampBounds(dragged_child);
            dragged_child.pos = mouse.add(drag.offset).clamp(clamp_bounds[0], clamp_bounds[1]);
        },
        else => {},
    }

    self.drawTopBar();
    try self.drawBottomPanel(gpa);

    if (self.mod_settings) |*settings| {
        rg.unlock();
        try self.drawSettingsMenu(gpa, settings);
    }

    if (self.child_settings) |*settings| {
        rg.unlock();
        drawChildSettingsMenu(&settings.v);
    }
}

fn drawChildSettingsMenu(settings: *Module.Settings) void {
    rl.drawRectangle(0, 0, consts.screen_width, consts.screen_height, theme.dim);

    switch (settings.*) {
        .logic_gate => |*s| drawLogicGateSettingsMenu(s),
    }
}

fn drawLogicGateSettingsMenu(settings: *Module.LogicGateSettings) void {
    _ = settings;
}

fn removeWire(self: *Self, gpa: Allocator, wire_key: CustomModule.WireKey) !void {
    const top_mod = self.topMod();
    const wire = top_mod.wires.get(wire_key).?;
    _ = top_mod.wires.remove(wire_key);

    const wire_width = top_mod.wireDestWidth(wire.to);
    const false_values = try gpa.alloc(bool, wire_width);
    defer gpa.free(false_values);

    @memset(false_values, false);

    try self.top_inst.writeWireDestUpdate(gpa, wire.to, false_values);
    try globals.saveCustomModules(gpa);
}

fn removeChild(self: *Self, gpa: Allocator, child_key: Child.Key) !void {
    const top_mod = self.topMod();
    var wire_iter = top_mod.wires.const_iterator();

    while (wire_iter.next()) |entry| {
        const wire = entry.val;

        const matches_from = wire.from == .child_output and wire.from.child_output.child_key.equals(child_key);
        const matches_to = wire.to == .child_input and wire.to.child_input.child_key.equals(child_key);

        if (matches_from or matches_to)
            try self.removeWire(gpa, entry.key);
    }

    _ = top_mod.children.remove(child_key);
    _ = self.top_inst.children.remove(child_key);
    try globals.saveCustomModules(gpa);
}

fn drawSettingsMenu(self: *Self, gpa: Allocator, settings: *ModuleSettings) !void {
    rl.drawRectangle(0, 0, consts.screen_width, consts.screen_height, theme.dim);

    const rect_size: Vector2 = .init(600, 400);
    const rect_pos: Vector2 = consts.screen_size.subtract(rect_size).scale(0.5);

    const win_rect: Rectangle = .init(rect_pos.x, rect_pos.y, rect_size.x, rect_size.y);
    const result = rg.windowBox(win_rect, "Module settings");

    if (result == 1) {
        try self.closeModSettings(gpa, settings, false);
        return;
    }

    const pad = 30;
    const font = rl.getFontDefault() catch unreachable;

    const delete_btn_size = 30;
    const delete_rect: Rectangle = .init(
        win_rect.x + win_rect.width - delete_btn_size - pad,
        win_rect.y + 40,
        delete_btn_size,
        delete_btn_size,
    );

    if (rg.button(delete_rect, comptimePrint("#{d}#", .{IconName.bin}))) {
        self.ctx.next_scene = .{ .selector = .{ .delete_mod = self.top_inst.mod_key } };
        try globals.saveCustomModules(gpa);
    }

    rl.drawTextEx(font, "Name:", .init(win_rect.x + pad, win_rect.y + 45), 24, 24 * 0.1, theme.text);

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
        theme.text,
    );

    const color_demo_rect: Rectangle = .init(win_rect.x + pad + 80, win_rect.y + 150, 24, 24);
    rl.drawRectangleRec(color_demo_rect, settings.color);
    rl.drawRectangleLinesEx(color_demo_rect, 1, theme.text_muted);

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
        try self.closeModSettings(gpa, settings, true);
}

fn openModSettings(self: *Self) void {
    const top_mod = self.topMod();

    self.mod_settings = .{
        .name = undefined,
        .name_edit_mode = true,
        .color = top_mod.color,
    };

    const n = top_mod.name.len + 1;
    @memcpy(self.mod_settings.?.name[0..n], top_mod.name.ptr[0..n]);
}

fn closeModSettings(self: *Self, gpa: Allocator, settings: *const ModuleSettings, save: bool) !void {
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

    self.mod_settings = null;
}

fn closeChildSettings(self: *Self, gpa: Allocator, child_key: Child.Key, settings: *const Module.Settings, save: bool) !void {
    if (save) {
        const top_mod = self.topMod();
        const child = top_mod.children.get(child_key).?;
        const child_inst = self.top_inst.children.get(child_key).?;

        switch (settings.*) {
            .logic_gate => |new| try self.saveLogicGateSettings(gpa, child_key, child, child_inst, new),
        }
    }

    self.child_settings = null;
}

fn saveLogicGateSettings(self: *Self, gpa: Allocator, child_key: Child.Key, child: *Child, child_inst: *ModuleInstance, new: Module.LogicGateSettings) !void {
    const top_mod = self.topMod();
    const gate = &child.mod.logic_gate;
    const gate_inst = &child_inst.logic_gate;

    if (new.input_cnt != gate.input_cnt) {
        if (new.input_cnt < gate.input_cnt) {
            // Remove wires connected to what we're about to delete
            var wire_iter = top_mod.wires.const_iterator();
            while (wire_iter.next()) |entry| {
                const dest = entry.val.to;

                if (dest == .child_input and dest.child_input.child_key.equals(child_key) and dest.child_input.input.logic_gate >= new.input_cnt)
                    _ = top_mod.wires.remove(entry.key);
            }

            gate_inst.inputs.shrinkRetainingCapacity(new.input_cnt);
        } else {
            try gate_inst.inputs.appendNTimes(gpa, false, new.input_cnt - gate_inst.inputs.items.len);
        }

        assert(gate_inst.inputs.items.len == gate.input_cnt);
        // TODO: propagate within top instance
        gate_inst.update();
        gate.input_cnt = new.input_cnt;
    }
}

fn openChildSettings(self: *Self, child_key: Child.Key) void {
    const child = self.top_inst.children.get(child_key).?;

    self.child_settings = .{
        .child_key = child_key,
        .v = switch (child.*) {
            .logic_gate => |*gate| .{ .logic_gate = .{ .input_cnt = gate.inputs.items.len } },
            .not_gate, .custom => unreachable,
        },
    };
}

fn drawTopBar(self: *Self) void {
    const top_mod = self.topMod();

    if (rg.button(.init(15, 10, 40, 40), comptimePrint("#{d}#", .{IconName.arrow_left})))
        self.ctx.next_scene = .{ .selector = .{ .delete_mod = null } };

    if (rg.button(.init(65, 10, 40, 40), comptimePrint("#{d}#", .{IconName.tools})))
        self.openModSettings();

    rl.drawText(top_mod.name, 125, 15, consts.font_size, theme.text);
}

const btn_spacing = 8;

const panel_height = 65;
const panel_rect: Rectangle = .init(
    15,
    consts.screen_height - panel_height - 10,
    consts.screen_width - 30,
    panel_height,
);

const btn_height = panel_rect.height - 24;

fn bottomButton(label: [:0]const u8, pos: *Vector2) bool {
    const measure: f32 = @floatFromInt(rl.measureText(label, consts.font_size));
    const btn_width = 20 + measure;

    const result = rg.button(.init(pos.x, pos.y, btn_width, btn_height), label);
    pos.x += btn_width + (2 * btn_spacing);
    return result;
}

fn childClampBounds(child: *const Child) struct { Vector2, Vector2 } {
    const bounds = childBounds(child);
    return .{
        .init(sim_rect.x, sim_rect.y),
        .init(
            sim_rect.x + sim_rect.width - bounds.width,
            sim_rect.y + sim_rect.height - bounds.height,
        ),
    };
}

fn addChildModule(self: *Self, gpa: Allocator, child_v: Module) !void {
    const top_mod = self.topMod();

    var child: Child = .init(consts.screen_size.scale(0.5), child_v);
    const child_inst: ModuleInstance = try .fromModule(gpa, &child.mod);

    const clamp_bounds = childClampBounds(&child);

    while (containsChildWithPos(&top_mod.children, child.pos)) {
        const new_pos = child.pos.addValue(25).clamp(clamp_bounds[0], clamp_bounds[1]);
        if (child.pos.equals(new_pos) != 0)
            break;

        child.pos = new_pos;
    }

    const child_key = try top_mod.children.put(gpa, child);
    _ = try self.top_inst.children.put(gpa, child_key, child_inst);

    self.selection = .{ .child = child_key };

    try globals.saveCustomModules(gpa);
}

fn drawBottomPanel(self: *Self, gpa: Allocator) !void {
    const panel_contents: Rectangle = .init(0, 0, self.panel_contents_width, panel_rect.height - 10);
    const panel_base = Vector2
        .init(panel_rect.x, panel_rect.y)
        .add(.init(panel_contents.x, panel_contents.y));

    _ = rg.scrollPanel(panel_rect, null, panel_contents, &self.panel_scroll, &self.panel_view);

    rl.drawRectangleLinesEx(panel_rect, 2, theme.text_muted);

    re.beginScissorModeRec(self.panel_view);
    defer rl.endScissorMode();

    var btn_pos = panel_base.addValue(btn_spacing).add(self.panel_scroll);

    for (std.enums.values(Module.LogicGate.Kind)) |kind| {
        if (bottomButton(@tagName(kind), &btn_pos)) {
            try self.addChildModule(gpa, .{
                .logic_gate = .{
                    .kind = kind,
                    .input_cnt = 2,
                },
            });
        }
    }

    if (bottomButton("not", &btn_pos))
        try self.addChildModule(gpa, .not_gate);

    var iter = globals.modules.const_iterator();
    while (iter.next()) |entry| {
        const mod = entry.val;

        re.guiSetEnabled(!self.disabled_modules.contains(entry.key));
        const pressed = bottomButton(mod.name, &btn_pos);

        if (pressed)
            try self.addChildModule(gpa, .{ .custom = entry.key });
    }

    rg.enable();
    self.panel_contents_width = btn_pos.x;
}

fn containsChildWithPos(children: *const SlotMap(Child), pos: Vector2) bool {
    var iter = children.const_iterator();
    while (iter.nextValue()) |child| {
        if (child.pos.distanceSqr(pos) < consts.epsilon_sqr)
            return true;
    }

    return false;
}

fn drawWire(self: *const Self, wire: *const Wire, highlight: bool) void {
    const wire_values = self.top_inst.readWireSrc(wire.from).?;
    const from_pos = self.wireSrcPos(&wire.from);
    const to_pos = self.wireDestPos(&wire.to);

    if (highlight)
        drawWireLines(
            from_pos,
            to_pos,
            wire.points,
            3 * wire_thick,
            theme.selection_border,
        );

    drawWireLines(from_pos, to_pos, wire.points, wire_thick, logicColor(wire_values));
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

fn drawSimulation(self: *Self, gpa: Allocator, mouse: Vector2, hover: HoverInfo) !void {
    rl.drawRectangleLinesEx(sim_rect, 2, theme.text_muted);

    re.beginScissorModeRec(sim_rect);
    defer rl.endScissorMode();

    const top_mod = self.topMod();

    var wire_iter = top_mod.wires.const_iterator();
    while (wire_iter.next()) |entry| {
        const highlight = self.selection == .wire and self.selection.wire.equals(entry.key);
        self.drawWire(entry.val, highlight);
    }

    const snapped_mouse = self.snapMouse(mouse);

    switch (self.mouse_action) {
        .wire_from => |from| {
            const from_value = self.top_inst.readWireSrc(from).?;
            const from_pos = self.wireSrcPos(&from);
            drawWireLines(from_pos, snapped_mouse, self.wire_points.items, wire_thick, logicColor(from_value));
        },
        .wire_to => |to| {
            const to_pos = self.wireDestPos(&to);
            drawWireLines(to_pos, snapped_mouse, self.wire_points.items, wire_thick, logicColor(&.{false}));
        },
        else => {},
    }

    var input_iter = top_mod.inputs.const_iterator();
    while (input_iter.next()) |entry| {
        const input_key = entry.key;
        const input = entry.val;

        const value = self.top_inst.inputs.get(input_key).?.*;
        const btn_pos = self.topInputBtnPos(input_key);
        const pin_pos = self.topInputPosPin(input_key);

        const highlight = hover == .top_input_pin and hover.top_input_pin.equals(input_key);

        rl.drawLineEx(btn_pos, pin_pos, 8, theme.port);
        rl.drawCircleV(pin_pos, top_port_radius_pin, if (highlight) theme.background_alt else theme.port);
        rl.drawCircleV(btn_pos, top_port_radius_btn, logicColor(value));

        const font = rl.getFontDefault() catch unreachable;
        const width_str = try std.fmt.allocPrintSentinel(gpa, "{d}", .{input.width}, 0);
        defer gpa.free(width_str);

        re.drawTextAligned(font, width_str, pin_pos, 20, 2, theme.text_muted, .center, .center);
    }

    var output_iter = top_mod.outputs.const_iterator();
    while (output_iter.next()) |entry| {
        const output_key = entry.key;
        const output = entry.val;

        const value = self.top_inst.outputs.get(output_key).?.*;
        const btn_pos = self.topOutputPosBtn(output_key);
        const pin_pos = self.topOutputPinPos(output_key);

        const highlight = hover == .top_output_pin and hover.top_output_pin.equals(output_key);

        rl.drawLineEx(btn_pos, pin_pos, 8, theme.port);
        rl.drawCircleV(pin_pos, top_port_radius_pin, if (highlight) theme.background_alt else theme.port);
        rl.drawCircleV(btn_pos, top_port_radius_btn, logicColor(value));

        const font = rl.getFontDefault() catch unreachable;
        const width_str = try std.fmt.allocPrintSentinel(gpa, "{d}", .{output.width}, 0);
        defer gpa.free(width_str);

        re.drawTextAligned(font, width_str, pin_pos, 20, 2, theme.text_muted, .center, .center);
    }

    var child_iter = top_mod.children.const_iterator();
    while (child_iter.nextKey()) |child_key|
        self.drawChild(child_key, hover);
}

fn snapMouse(self: *const Self, mouse: Vector2) Vector2 {
    if (!rl.isKeyDown(.left_shift))
        return mouse;

    switch (self.mouse_action) {
        .wire_from => |from| {
            const from_pos = self.wireSrcPos(&from);
            const last_point = self.wire_points.getLastOrNull() orelse from_pos;
            return math.snap(last_point, mouse);
        },
        .wire_to => |to| {
            const to_pos = self.wireDestPos(&to);
            const last_point = self.wire_points.getLastOrNull() orelse to_pos;
            return math.snap(last_point, mouse);
        },
        else => return mouse,
    }
}

fn moduleRectangle(pos: Vector2, label: [:0]const u8, ports: usize) Rectangle {
    const port_spacing = 6;

    const measure: f32 = @floatFromInt(rl.measureText(label, consts.font_size));
    const portsf: f32 = @floatFromInt(ports);

    return .init(
        pos.x,
        pos.y,
        40 + measure,
        (portsf * (2 * port_radius)) + ((portsf + 1) * port_spacing),
    );
}

fn logicGateBounds(pos: Vector2, gate: *const Module.LogicGate) Rectangle {
    return moduleRectangle(pos, @tagName(gate.kind), gate.input_cnt);
}

fn notGateBounds(pos: Vector2) Rectangle {
    return moduleRectangle(pos, "not", 1);
}

fn customModuleBounds(pos: Vector2, module: *const CustomModule) Rectangle {
    return moduleRectangle(
        pos,
        module.name,
        @max(module.inputs.size, module.outputs.size),
    );
}

fn childBounds(child: *const Child) Rectangle {
    return switch (child.mod) {
        .logic_gate => |*gate| logicGateBounds(child.pos, gate),
        .not_gate => notGateBounds(child.pos),
        .custom => |mod_key| customModuleBounds(child.pos, globals.modules.get(mod_key).?),
    };
}

const selection_pad = 8;

fn drawLogicGate(gate: *const Module.LogicGate, pos: Vector2, hovered_input: bool, hovered_output: bool, hover: HoverInfo, selected: bool) void {
    const font = rl.getFontDefault() catch unreachable;
    const bounds = logicGateBounds(pos, gate);
    const bounds_center = re.rectCenter(bounds);

    const color = switch (gate.kind) {
        .@"and" => theme.and_gate,
        .nand => theme.nand_gate,
        .@"or" => theme.or_gate,
        .nor => theme.nor_gate,
        .xor => theme.xor_gate,
    };

    if (selected)
        rl.drawRectangleRec(re.rectPad(bounds, selection_pad), theme.selection_border);

    rl.drawRectangleRec(bounds, color);
    re.drawTextAligned(font, @tagName(gate.kind), bounds_center, consts.font_size, consts.font_spacing, theme.text, .center, .center);

    for (0..gate.input_cnt) |input| {
        const highlight = hovered_input and hover.child_input.input.logic_gate == input;

        rl.drawCircleV(
            logicGateInputPos(gate, pos, input),
            port_radius,
            if (highlight) theme.background_alt else theme.port,
        );
    }

    rl.drawCircleV(
        logicGateOutputPos(gate, pos),
        port_radius,
        if (hovered_output) theme.background_alt else theme.port,
    );
}

fn drawNotGate(pos: Vector2, hovered_input: bool, hovered_output: bool, selected: bool) void {
    const font = rl.getFontDefault() catch unreachable;
    const bounds = notGateBounds(pos);
    const bounds_center = re.rectCenter(bounds);

    if (selected)
        rl.drawRectangleRec(re.rectPad(bounds, selection_pad), theme.selection_border);

    rl.drawRectangleRec(bounds, theme.not_gate);
    re.drawTextAligned(font, "not", bounds_center, consts.font_size, consts.font_spacing, theme.text, .center, .center);

    rl.drawCircleV(
        notGateInputPos(pos),
        port_radius,
        if (hovered_input) theme.background_alt else theme.port,
    );

    rl.drawCircleV(
        notGateOutputPos(pos),
        port_radius,
        if (hovered_output) theme.background_alt else theme.port,
    );
}

fn drawCustomModule(mod_key: CustomModule.Key, pos: Vector2, hovered_input: bool, hovered_output: bool, hover: HoverInfo, selected: bool) void {
    const font = rl.getFontDefault() catch unreachable;
    const mod = globals.modules.get(mod_key).?;
    const bounds = customModuleBounds(pos, mod);
    const bounds_center = re.rectCenter(bounds);

    if (selected)
        rl.drawRectangleRec(re.rectPad(bounds, selection_pad), theme.selection_border);

    rl.drawRectangleRec(bounds, mod.color);

    var input_iter = mod.inputs.const_iterator();
    while (input_iter.nextKey()) |input_key| {
        const highlight = hovered_input and hover.child_input.input.custom.equals(input_key);

        rl.drawCircleV(
            customModuleInputPos(mod, pos, input_key),
            port_radius,
            if (highlight) theme.background_alt else theme.port,
        );
    }

    var output_iter = mod.outputs.const_iterator();
    while (output_iter.nextKey()) |output_key| {
        const highlight = hovered_output and hover.child_output.output.custom.equals(output_key);

        rl.drawCircleV(
            customModuleOutputPos(mod, pos, output_key),
            port_radius,
            if (highlight) theme.background_alt else theme.port,
        );
    }

    re.drawTextAligned(font, mod.name, bounds_center, consts.font_size, consts.font_spacing, theme.text, .center, .center);
}

fn drawChild(self: *Self, child_key: Child.Key, hover: HoverInfo) void {
    const top_mod = self.topMod();
    const child = top_mod.children.get(child_key).?;

    const selected = self.selection == .child and self.selection.child.equals(child_key);

    // All module kinds use this to draw a rect, at least for now.
    const hovered_input = hover == .child_input and hover.child_input.child_key.equals(child_key);
    const hovered_output = hover == .child_output and hover.child_output.child_key.equals(child_key);

    switch (child.mod) {
        .logic_gate => |*gate| drawLogicGate(gate, child.pos, hovered_input, hovered_output, hover, selected),
        .not_gate => drawNotGate(child.pos, hovered_input, hovered_output, selected),
        .custom => |mod_key| drawCustomModule(mod_key, child.pos, hovered_input, hovered_output, hover, selected),
    }

    if (selected) {
        const cur_settings = child.mod.currentSettings();
        if (cur_settings) |cur_settings_v| {
            const bounds = childBounds(child);

            const btn_size = 30;
            const btn_rect: Rectangle = .init(
                bounds.x + bounds.width + 15,
                bounds.y - btn_size - 10,
                btn_size,
                btn_size,
            );

            if (rg.button(btn_rect, comptimePrint("#{d}#", .{IconName.gear}))) {
                self.child_settings = .{
                    .child_key = child_key,
                    .v = cur_settings_v,
                };
            }
        }
    }
}

fn addWire(self: *Self, gpa: Allocator, wire: Wire) !void {
    const top_mod = self.topMod();

    // Only create wire if port widths match
    if (top_mod.wireSrcWidth(wire.from) == top_mod.wireDestWidth(wire.to)) {
        const new_wire_key = try top_mod.addWireOrModifyExisting(gpa, wire);
        try self.top_inst.updateFromSrcsVoid(gpa, &.{wire.from});
        self.selection = .{ .wire = new_wire_key };
    }

    self.mouse_action = .none;

    try globals.saveCustomModules(gpa);
}

fn onClick(self: *Self, gpa: Allocator, hover: HoverInfo, mouse: Vector2) !void {
    const top_mod = self.topMod();
    const snapped_mouse = self.snapMouse(mouse);

    switch (self.mouse_action) {
        .wire_from => |from| switch (hover) {
            .child_input => |info| {
                const new_wire: Wire = try .init(gpa, from, .{ .child_input = info }, self.wire_points.items);
                try self.addWire(gpa, new_wire);
            },
            .top_output_pin => |idx| {
                const new_wire: Wire = try .init(gpa, from, .{ .top_output = idx }, self.wire_points.items);
                try self.addWire(gpa, new_wire);
            },
            else => try self.wire_points.append(gpa, snapped_mouse),
        },
        .wire_to => |to| {
            var points_rev = try self.wire_points.clone(gpa);
            defer points_rev.deinit(gpa);

            std.mem.reverse(Vector2, points_rev.items);

            switch (hover) {
                .child_output => |info| {
                    const new_wire: Wire = try .init(gpa, .{ .child_output = info }, to, points_rev.items);
                    try self.addWire(gpa, new_wire);
                },
                .top_input_pin => |idx| {
                    const new_wire: Wire = try .init(gpa, .{ .top_input = idx }, to, points_rev.items);
                    try self.addWire(gpa, new_wire);
                },
                else => try self.wire_points.append(gpa, snapped_mouse),
            }
        },
        .drag_module => {},
        .none => {
            switch (hover) {
                .none => {},
                .top_input_btn => |input_key| {
                    const prev_values = self.top_inst.inputs.get(input_key).?.*;
                    const dest_values = self.top_inst.inputs.get(input_key).?.*;

                    for (0.., prev_values) |i, v|
                        dest_values[i] = !v;

                    try self.top_inst.updateFromSrcsVoid(gpa, &.{.{ .top_input = input_key }});
                },
                .top_input_pin => |input_key| {
                    self.mouse_action = .{ .wire_from = .{ .top_input = input_key } };
                    self.wire_points.clearAndFree(gpa);
                },
                .top_output_pin => |output_key| {
                    self.mouse_action = .{ .wire_to = .{ .top_output = output_key } };
                    self.wire_points.clearAndFree(gpa);
                },
                .child => |child_key| {
                    self.selection = .{ .child = child_key };

                    self.mouse_action = .{
                        .drag_module = .{
                            .child_key = child_key,
                            .offset = top_mod.children.get(child_key).?.pos.subtract(mouse),
                        },
                    };
                },
                .child_input => |info| {
                    self.mouse_action = .{ .wire_to = .{ .child_input = info } };
                    self.wire_points.clearAndFree(gpa);
                },
                .child_output => |info| {
                    self.mouse_action = .{ .wire_from = .{ .child_output = info } };
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

fn onUnclick(self: *Self, gpa: Allocator) !void {
    switch (self.mouse_action) {
        .drag_module => {
            self.mouse_action = .none;
            try globals.saveCustomModules(gpa);
        },
        else => {},
    }
}

fn getHoverInfo(self: *const Self, mouse: Vector2) HoverInfo {
    if (self.mod_settings != null)
        return .none;

    const top_mod = self.topMod();

    var input_iter = top_mod.inputs.const_iterator();
    while (input_iter.nextKey()) |input_key| {
        if (mouse.distance(self.topInputBtnPos(input_key)) <= top_port_radius_btn)
            return .{ .top_input_btn = input_key };

        if (mouse.distance(self.topInputPosPin(input_key)) <= top_port_radius_pin)
            return .{ .top_input_pin = input_key };
    }

    var output_iter = top_mod.outputs.const_iterator();
    while (output_iter.nextKey()) |output_key| {
        if (mouse.distance(self.topOutputPinPos(output_key)) <= top_port_radius_pin)
            return .{ .top_output_pin = output_key };
    }

    var child_iter = top_mod.children.rev_iterator();

    while (child_iter.next()) |entry| {
        const child = entry.val;

        switch (child.mod) {
            .logic_gate => |*gate| {
                for (0..gate.input_cnt) |input| {
                    const input_pos = logicGateInputPos(gate, child.pos, input);

                    if (mouse.distance(input_pos) <= port_radius) {
                        return .{
                            .child_input = .{
                                .child_key = entry.key,
                                .input = .{ .logic_gate = input },
                            },
                        };
                    }
                }

                const output_pos = logicGateOutputPos(gate, child.pos);
                if (mouse.distance(output_pos) <= port_radius) {
                    return .{
                        .child_output = .{
                            .child_key = entry.key,
                            .output = .logic_gate,
                        },
                    };
                }
            },
            .not_gate => {
                const input_pos = notGateInputPos(child.pos);
                const output_pos = notGateOutputPos(child.pos);

                if (mouse.distance(input_pos) <= port_radius) {
                    return .{
                        .child_input = .{
                            .child_key = entry.key,
                            .input = .not_gate,
                        },
                    };
                }

                if (mouse.distance(output_pos) <= port_radius) {
                    return .{
                        .child_output = .{
                            .child_key = entry.key,
                            .output = .not_gate,
                        },
                    };
                }
            },
            .custom => |mod_key| {
                const child_mod = globals.modules.get(mod_key).?;

                input_iter = child_mod.inputs.const_iterator();
                while (input_iter.nextKey()) |input_key| {
                    const input_pos = customModuleInputPos(child_mod, child.pos, input_key);

                    if (mouse.distance(input_pos) <= port_radius) {
                        return .{
                            .child_input = .{
                                .child_key = entry.key,
                                .input = .{ .custom = input_key },
                            },
                        };
                    }
                }

                output_iter = child_mod.outputs.const_iterator();
                while (output_iter.nextKey()) |output_key| {
                    const output_pos = customModuleOutputPos(child_mod, child.pos, output_key);

                    if (mouse.distance(output_pos) <= port_radius) {
                        return .{
                            .child_output = .{
                                .child_key = entry.key,
                                .output = .{ .custom = output_key },
                            },
                        };
                    }
                }
            },
        }

        const bounds = childBounds(child);

        if (math.checkVec2RectCollision(mouse, bounds))
            return .{ .child = entry.key };
    }

    var wire_iter = top_mod.wires.const_iterator();

    while (wire_iter.next()) |entry| {
        const wire = entry.val;
        const from_pos = self.wireSrcPos(&wire.from);
        const to_pos = self.wireDestPos(&wire.to);

        var s = from_pos;

        for (wire.points) |p| {
            if (math.touchesSegment(mouse, s, p, 10))
                return .{ .wire = entry.key };

            s = p;
        }

        if (math.touchesSegment(mouse, s, to_pos, 10))
            return .{ .wire = entry.key };
    }

    return .none;
}

fn logicGateInputPos(module: *const Module.LogicGate, base_pos: Vector2, input: usize) Vector2 {
    const bounds = logicGateBounds(base_pos, module);
    const y_offset = math.interpolate(module.input_cnt, input, bounds.height + (2 * port_radius));

    return .init(base_pos.x, base_pos.y - port_radius + y_offset);
}

fn logicGateOutputPos(module: *const Module.LogicGate, base_pos: Vector2) Vector2 {
    const bounds = logicGateBounds(base_pos, module);
    return .init(base_pos.x + bounds.width, base_pos.y + (bounds.height / 2));
}

fn notGateInputPos(base_pos: Vector2) Vector2 {
    const bounds = notGateBounds(base_pos);
    return .init(base_pos.x, base_pos.y + (bounds.height / 2));
}

fn notGateOutputPos(base_pos: Vector2) Vector2 {
    const bounds = notGateBounds(base_pos);
    return .init(base_pos.x + bounds.width, base_pos.y + (bounds.height / 2));
}

fn customModuleInputPos(module: *const CustomModule, base_pos: Vector2, input_key: CustomModule.InputKey) Vector2 {
    const input = module.inputs.get(input_key).?;
    const bounds = customModuleBounds(base_pos, module);

    return .init(
        base_pos.x,
        base_pos.y + (input.pos * bounds.height),
    );
}

fn customModuleOutputPos(module: *const CustomModule, base_pos: Vector2, output_key: CustomModule.OutputKey) Vector2 {
    const bounds = customModuleBounds(base_pos, module);
    const output = module.outputs.get(output_key).?;

    return .init(
        base_pos.x + bounds.width,
        base_pos.y + (output.pos * bounds.height),
    );
}

fn topInputBtnPos(self: *const Self, input_key: CustomModule.InputKey) Vector2 {
    const input = self.topMod().inputs.get(input_key).?;

    return .init(
        2 * top_port_radius_btn,
        sim_rect.x + (input.pos * sim_rect.height),
    );
}

fn topInputPosPin(self: *const Self, input_key: CustomModule.InputKey) Vector2 {
    return self.topInputBtnPos(input_key).add(.init(top_port_btn_pin_distance, 0));
}

fn topOutputPosBtn(self: *const Self, output_key: CustomModule.OutputKey) Vector2 {
    const output = self.topMod().outputs.get(output_key).?;

    return .init(
        consts.screen_width - (2 * top_port_radius_btn),
        sim_rect.x + (output.pos * sim_rect.height),
    );
}

fn topOutputPinPos(self: *const Self, output_key: CustomModule.OutputKey) Vector2 {
    const btn_pos = self.topOutputPosBtn(output_key);
    return btn_pos.subtract(.init(top_port_btn_pin_distance, 0));
}

fn wireSrcPos(self: *const Self, src: *const WireSrc) Vector2 {
    switch (src.*) {
        .top_input => |input_key| return self.topInputPosPin(input_key),
        .child_output => |keys| {
            const child = self.topMod().children.get(keys.child_key).?;
            return switch (child.mod) {
                .logic_gate => |*gate| logicGateOutputPos(gate, child.pos),
                .not_gate => notGateOutputPos(child.pos),
                .custom => |key| customModuleOutputPos(globals.modules.get(key).?, child.pos, keys.output.custom),
            };
        },
    }
}

fn wireDestPos(self: *const Self, dest: *const WireDest) Vector2 {
    switch (dest.*) {
        .top_output => |output_key| return self.topOutputPinPos(output_key),
        .child_input => |keys| {
            const child = self.topMod().children.get(keys.child_key).?;
            return switch (child.mod) {
                .logic_gate => |*gate| logicGateInputPos(gate, child.pos, keys.input.logic_gate),
                .not_gate => notGateInputPos(child.pos),
                .custom => |mod_key| blk: {
                    const child_mod = globals.modules.get(mod_key).?;
                    break :blk customModuleInputPos(child_mod, child.pos, keys.input.custom);
                },
            };
        },
    }
}

inline fn logicColor(values: []const bool) Color {
    return if (std.mem.allEqual(bool, values, false)) theme.logic_off else theme.logic_on;
}

inline fn topMod(self: *const Self) *CustomModule {
    return globals.modules.get(self.top_inst.mod_key).?;
}
