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
const DefaultPrng = std.Random.DefaultPrng;
const Vector2 = rl.Vector2;
const Rectangle = rl.Rectangle;
const Color = rl.Color;
const Font = rl.Font;
const IconName = rg.IconName;
const SlotMap = structs.SlotMap;
const SecondaryMap = structs.SecondaryMap;
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
const allocPrintSentinel = std.fmt.allocPrintSentinel;

const wire_thick = 5;
const port_radius = 12;
const top_port_radius_btn = 20;
const top_port_btn_pin_distance = 45;
const sim_rect: Rectangle = .init(
    15,
    60,
    consts.screen_width - 30,
    consts.screen_height - 140,
);

const win_pad = 30;

const menu_label_space = 10;
const menu_element_space = 20;

const HoverInfo = union(enum) {
    none,
    top_input_btn: CustomModule.PortKey,
    top_input_pin: CustomModule.PortKey,
    top_output_pin: CustomModule.PortKey,
    child_input: CustomModule.ChildInputRef,
    child_output: CustomModule.ChildOutputRef,
    child: Child.Key,
    wire: CustomModule.WireKey,

    pub fn isChildInput(self: @This(), child_key: Child.Key) bool {
        return self == .mod_input and self.child_input.child_key.equals(child_key);
    }

    pub fn isChildOutput(self: @This(), child_key: Child.Key) bool {
        return self == .mod_output and self.child_output.child_key.equals(child_key);
    }
};

const ModuleSettings = struct {
    pub const PortSettings = struct {
        name_buf: [consts.max_input_name_size]u8,
        width: usize,
        order: usize,
        name_edit_mode: bool,
        width_edit_mode: bool,

        pub fn init(width: usize, order: usize) @This() {
            var out: @This() = .{
                .name_buf = undefined,
                .width = width,
                .order = order,
                .name_edit_mode = false,
                .width_edit_mode = false,
            };

            out.name_buf[0] = 0;
            return out;
        }

        pub fn initFromPort(port: CustomModule.Port) @This() {
            var out: @This() = .{
                .name_buf = undefined,
                .order = port.order,
                .width = port.width,
                .name_edit_mode = false,
                .width_edit_mode = false,
            };

            if (port.name) |name| {
                const n = name.len + 1;
                @memcpy(out.name_buf[0..n], name.ptr[0..n]);
            } else {
                out.name_buf[0] = 0;
            }

            return out;
        }
    };

    pub const PortSettingsContainers = struct {
        cur: SecondaryMap(CustomModule.PortKey, PortSettings),
        new: ArrayList(PortSettings),

        pub fn init(cur: SecondaryMap(CustomModule.PortKey, PortSettings)) @This() {
            return .{ .cur = cur, .new = .empty };
        }

        pub fn deinit(self: *@This(), gpa: Allocator) void {
            self.cur.deinit(gpa);
            self.new.deinit(gpa);
            self.* = undefined;
        }

        pub fn count(self: @This()) usize {
            return self.cur.count + self.new.items.len;
        }

        pub fn decreaseOrders(self: *@This(), from: usize) void {
            var sub_input_iter = self.cur.iterator();
            while (sub_input_iter.nextValue()) |s| {
                if (s.order > from)
                    s.order -= 1;
            }

            for (self.new.items) |*s| {
                if (s.order > from)
                    s.order -= 1;
            }
        }
    };

    name_buf: [consts.max_mod_name_size]u8,
    name_edit_mode: bool,
    color: Color,
    inputs: PortSettingsContainers,
    outputs: PortSettingsContainers,

    pub fn deinit(self: *@This(), gpa: Allocator) void {
        self.inputs.deinit(gpa);
        self.outputs.deinit(gpa);
        self.* = undefined;
    }
};

ctx: *GameContext,
prng: *DefaultPrng,
top_inst: CustomModuleInstance,
last_click: f64,
time: u64,
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
debounce_timer: usize,

const init_time = 0;

pub fn init(gpa: Allocator, ctx: *GameContext, mod_key: CustomModule.Key) !Self {
    const prng = try gpa.create(DefaultPrng);

    prng.* = .init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });

    sim.initPrng(prng);

    var disabled_modules: AutoHashMap(CustomModule.Key, void) = .init(gpa);

    var mod_iter = globals.modules.constIterator();
    while (mod_iter.nextKey()) |key| {
        if (CustomModule.dependsOn(key, mod_key))
            try disabled_modules.put(key, {});
    }

    return .{
        .ctx = ctx,
        .prng = prng,
        .last_click = 0,
        .top_inst = try .init(gpa, mod_key, init_time),
        .time = init_time,
        .disabled_modules = disabled_modules,
        .mouse_action = .none,
        .wire_points = .empty,
        .selection = .none,
        .panel_view = .init(0, 0, 0, 0),
        .panel_scroll = .init(0, 0),
        .panel_contents_width = 0,
        .mod_settings = null,
        .child_settings = null,
        .debounce_timer = 0,
    };
}

pub fn deinit(self: *Self, gpa: Allocator) void {
    self.top_inst.deinit(gpa);
    self.wire_points.deinit(gpa);
    self.disabled_modules.deinit();

    if (self.mod_settings) |*settings|
        settings.deinit(gpa);

    if (self.child_settings) |*settings|
        settings.v.deinit(gpa);

    gpa.destroy(self.prng);
    self.* = undefined;
}

pub fn frame(self: *Self, gpa: Allocator) !void {
    if (self.debounce_timer != 0)
        self.debounce_timer -= 1;

    rg.unlock();

    if (self.mod_settings != null or self.child_settings != null)
        rg.lock();

    const top_mod = self.topModPtr();

    const mouse = rl.getMousePosition();
    const hover = try self.getHoverInfo(gpa, mouse);

    rl.setMouseCursor(if (hover == .none) .default else .pointing_hand);

    rl.clearBackground(theme.background);
    try self.drawSimulation(gpa, mouse, hover);

    if (rl.isMouseButtonPressed(.left)) {
        try self.onClick(gpa, hover, mouse);

        const time = rl.getTime();
        if (time - self.last_click < consts.double_click_secs) {
            try self.onDoubleClick(gpa, hover);
            self.last_click = 0;
        } else {
            self.last_click = time;
        }
    } else if (rl.isMouseButtonReleased(.left)) {
        try self.onUnclick(gpa);
    }

    if (rl.isMouseButtonPressed(.right))
        self.onRightClick();

    if (rl.isKeyPressed(consts.escape_key)) {
        if (self.mod_settings != null) {
            try self.closeModSettings(gpa, false);
            self.mod_settings = null;
        } else if (self.child_settings) |_| {
            try self.closeChildSettings(gpa, false);
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
            const dragged_child = top_mod.children.getPtr(drag.child_key).?;
            const clamp_bounds = try childClampBounds(gpa, dragged_child.*);
            dragged_child.pos = mouse.add(drag.offset).clamp(clamp_bounds[0], clamp_bounds[1]);
        },
        else => {},
    }

    try self.drawTopBar(gpa);
    try self.drawBottomPanel(gpa);

    if (self.mod_settings) |*settings| {
        rg.unlock();
        try self.drawModSettingsMenu(gpa, settings);
    }

    if (self.child_settings) |*settings| {
        rg.unlock();
        try self.drawChildSettingsMenu(gpa, &settings.v);
    }

    try self.simulateDelta(gpa, rl.getFrameTime());

    switch (hover) {
        .child_input => |ref| {
            const child = self.topModPtr().children.get(ref.child_key).?;
            if (child.mod.getInputTooltip(ref.input)) |input_name|
                re.drawTooltip(input_name);
        },
        .child_output => |ref| {
            const child = self.topModPtr().children.get(ref.child_key).?;
            if (child.mod.getOutputTooltip(ref.output)) |output_name|
                re.drawTooltip(output_name);
        },
        .top_input_pin => |input_key| {
            if (top_mod.inputs.get(input_key).?.name) |input_name|
                re.drawTooltip(input_name);
        },
        .top_output_pin => |output_key| {
            if (top_mod.outputs.get(output_key).?.name) |output_name|
                re.drawTooltip(output_name);
        },
        else => {},
    }
}

fn simulateDelta(self: *Self, gpa: Allocator, delta: f32) !void {
    self.time += @intFromFloat(consts.logic_time_per_sec * delta);

    while (self.top_inst.nextEventTime()) |nt| {
        if (nt >= self.time)
            break;

        const affected = try self.top_inst.processEvent(gpa);

        defer gpa.free(affected);
        defer for (affected) |*af| af.deinit(gpa);
    }
}

fn drawChildSettingsMenu(self: *Self, gpa: Allocator, settings: *Module.Settings) !void {
    rl.drawRectangle(0, 0, consts.screen_width, consts.screen_height, theme.dim);

    if (rl.isKeyPressed(.enter)) {
        try self.closeChildSettings(gpa, true);
        return;
    }

    switch (settings.*) {
        .logic_gate => |*s| try self.drawLogicGateSettingsMenu(gpa, s),
        .split => |*s| try self.drawSplitSettingsMenu(gpa, s),
        .join => |*s| try self.drawJoinSettingsMenu(gpa, s),
        .clock => |*s| try self.drawClockSettingsMenu(gpa, s),
    }
}

fn drawLogicGateSettingsMenu(self: *Self, gpa: Allocator, settings: *Module.LogicGateSettings) !void {
    const win_rect = re.rectWithCenter(consts.screen_size.scale(0.5), .init(400, 220));

    if (rg.windowBox(win_rect, "Logic gate settings") == 1) {
        try self.closeChildSettings(gpa, false);
        return;
    }

    var cur_rect = win_rect;
    _ = re.rectTakeTop(&cur_rect, 20); // window header height
    cur_rect = re.rectPad(cur_rect, -win_pad, -win_pad);

    const font = rl.getFontDefault() catch unreachable;

    var input_cnt_rect = re.rectTakeTop(&cur_rect, 30);
    const input_cnt_box = re.rectTakeRight(&input_cnt_rect, 60);
    _ = re.rectTakeTop(&cur_rect, menu_element_space);

    re.drawTextAligned(
        font,
        "Input count:",
        .init(input_cnt_rect.x, input_cnt_rect.y + (input_cnt_rect.height / 2)),
        24,
        2.4,
        theme.text,
        .left,
        .center,
    );

    re.valueBoxT(usize, input_cnt_box, "", &settings.input_cnt, 2, 32, &settings.input_cnt_edit);

    var single_wire_rect = re.rectTakeTop(&cur_rect, 30);
    const single_wire_box = re.rectPad(re.rectTakeRight(&single_wire_rect, single_wire_rect.height), -5, -5);

    re.drawTextAligned(
        font,
        "Single wire:",
        .init(single_wire_rect.x, single_wire_rect.y + (single_wire_rect.height / 2)),
        24,
        2.4,
        theme.text,
        .left,
        .center,
    );

    _ = rg.checkBox(single_wire_box, "", &settings.single_wire);

    const save_btn_rect = re.rectTakeBottom(&cur_rect, 24);

    if (rg.button(save_btn_rect, "Save")) {
        try self.closeChildSettings(gpa, true);
        return;
    }
}

fn drawSplitSettingsMenu(self: *Self, gpa: Allocator, settings: *Module.SplitSettings) !void {
    const win_rect = re.rectWithCenter(consts.screen_size.scale(0.5), .init(400, 220));

    if (rg.windowBox(win_rect, "Split settings") == 1) {
        try self.closeChildSettings(gpa, false);
        return;
    }

    var cur_rect = win_rect;
    _ = re.rectTakeTop(&cur_rect, 20); // window header height
    cur_rect = re.rectPad(cur_rect, -win_pad, -win_pad);

    const font = rl.getFontDefault() catch unreachable;

    var input_width_rect = re.rectTakeTop(&cur_rect, 30);
    const input_width_box = re.rectTakeRight(&input_width_rect, 60);
    _ = re.rectTakeTop(&cur_rect, menu_element_space);

    re.drawTextAligned(
        font,
        "Input width:",
        .init(input_width_rect.x, input_width_rect.y + (input_width_rect.height / 2)),
        24,
        2.4,
        theme.text,
        .left,
        .center,
    );

    re.valueBoxT(usize, input_width_box, "", &settings.input_width, consts.min_port_width, consts.max_port_width, &settings.input_width_edit);

    var output_range_rect = re.rectTakeTop(&cur_rect, 30);
    const output_from_box = re.rectTakeRight(&output_range_rect, 60);
    const colon_box = re.rectTakeRight(&output_range_rect, 16);
    const output_to_box = re.rectTakeRight(&output_range_rect, 60);

    re.drawTextAligned(
        font,
        "Output range:",
        re.rectAnchor(output_range_rect, .left, .center),
        24,
        2.4,
        theme.text,
        .left,
        .center,
    );

    const fixed_input_width = @max(settings.input_width, consts.min_port_width);

    re.valueBoxT(usize, output_to_box, "", &settings.output_to, settings.output_from, fixed_input_width - 1, &settings.output_to_edit);
    re.drawTextAligned(font, ":", re.rectCenter(colon_box), 24, 2.4, theme.text, .center, .center);
    re.valueBoxT(usize, output_from_box, "", &settings.output_from, 0, fixed_input_width - 1, &settings.output_from_edit);

    const save_btn_rect = re.rectTakeBottom(&cur_rect, 24);

    if (rg.button(save_btn_rect, "Save")) {
        try self.closeChildSettings(gpa, true);
        return;
    }
}

fn drawJoinSettingsMenu(self: *Self, gpa: Allocator, settings: *Module.JoinSettings) !void {
    const win_rect = re.rectWithCenter(consts.screen_size.scale(0.5), .init(360, 350));

    if (rg.windowBox(win_rect, "Join settings") == 1) {
        try self.closeChildSettings(gpa, false);
        return;
    }

    const font = rl.getFontDefault() catch unreachable;

    var cur_rect = win_rect;
    _ = re.rectTakeTop(&cur_rect, 20); // window header height
    cur_rect = re.rectPad(cur_rect, -win_pad, -win_pad);

    var inputs_lbl_rect = re.rectTakeTop(&cur_rect, 30);
    const new_input_rect = re.rectTakeRight(&inputs_lbl_rect, 40);
    _ = re.rectTakeTop(&cur_rect, menu_label_space);
    const inputs_rect = re.rectTakeTop(&cur_rect, 140);
    _ = re.rectTakeTop(&cur_rect, menu_element_space);

    re.drawTextAligned(font, "Inputs:", re.rectAnchor(inputs_lbl_rect, .left, .center), 24, 2.4, theme.text, .left, .center);

    if (rg.button(new_input_rect, "+")) {
        try settings.inputs.append(gpa, .{
            .width = 1,
            .edit = false,
        });
    }

    const item_height = 30;
    const item_space = 5;

    var inputs_rect_inner = re.rectPad(inputs_rect, -8, -8);
    inputs_rect_inner.width -= 16;

    const inputs_content_rect: Rectangle = .init(
        inputs_rect_inner.x, // to prevent horizontal bar
        inputs_rect_inner.y,
        inputs_rect_inner.width,
        @as(f32, @floatFromInt(settings.inputs.items.len)) * (item_height + item_space) - item_space,
    );

    _ = rg.scrollPanel(inputs_rect, null, inputs_content_rect, &settings.panel_scroll, &settings.panel_view);

    var cur_slice_from: usize = 0;

    {
        re.beginScissorModeRec(inputs_rect);
        defer rl.endScissorMode();

        var to_delete: ?usize = null;

        for (0.., settings.inputs.items) |i, *input| {
            var rect: Rectangle = .init(
                inputs_rect_inner.x + settings.panel_scroll.x,
                inputs_rect_inner.y + @as(f32, @floatFromInt(i)) * (item_height + item_space) + settings.panel_scroll.y,
                inputs_rect_inner.width,
                item_height,
            );

            const trash_box = re.rectTakeRight(&rect, 60);
            _ = re.rectTakeRight(&rect, 10);
            const width_box = re.rectTakeLeft(&rect, 60);

            const range_str = try allocPrintSentinel(gpa, "{d}:{d}", .{ cur_slice_from + input.width - 1, cur_slice_from }, 0);
            defer gpa.free(range_str);

            re.drawTextAligned(font, range_str, re.rectAnchor(rect, .center, .center), 24, 2.4, theme.text, .center, .center);
            re.valueBoxT(usize, width_box, "", &input.width, consts.min_port_width, consts.max_port_width, &input.edit);

            if (rg.button(trash_box, comptimePrint("#{d}#", .{IconName.bin})))
                to_delete = i;

            cur_slice_from += input.width;
        }

        if (to_delete) |idx|
            _ = settings.inputs.orderedRemove(idx);
    }

    const output_width_rect = re.rectTakeTop(&cur_rect, 30);
    const output_width_str = try allocPrintSentinel(gpa, "Output width: {d}", .{cur_slice_from}, 0);
    defer gpa.free(output_width_str);

    re.drawTextAligned(font, output_width_str, re.rectAnchor(output_width_rect, .center, .center), 24, 2.4, theme.text, .center, .center);

    const save_btn_rect = re.rectTakeBottom(&cur_rect, 24);

    if (rg.button(save_btn_rect, "Save")) {
        try self.closeChildSettings(gpa, true);
        return;
    }
}

fn drawClockSettingsMenu(self: *Self, gpa: Allocator, settings: *Module.ClockSettings) !void {
    const win_rect = re.rectWithCenter(consts.screen_size.scale(0.5), .init(400, 160));

    if (rg.windowBox(win_rect, "Clock settings") == 1) {
        try self.closeChildSettings(gpa, false);
        return;
    }

    var cur_rect = win_rect;
    _ = re.rectTakeTop(&cur_rect, 20); // window header height
    cur_rect = re.rectPad(cur_rect, -win_pad, -win_pad);

    const font = rl.getFontDefault() catch unreachable;

    var input_width_rect = re.rectTakeTop(&cur_rect, 30);
    const input_width_box = re.rectTakeRight(&input_width_rect, 80);
    _ = re.rectTakeTop(&cur_rect, menu_element_space);

    re.drawTextAligned(
        font,
        "Frequency (Hz):",
        .init(input_width_rect.x, input_width_rect.y + (input_width_rect.height / 2)),
        24,
        2.4,
        theme.text,
        .left,
        .center,
    );

    re.valueBoxFloat(input_width_box, "", &settings.freq_text, &settings.freq, &settings.freq_edit);
    settings.freq = std.math.clamp(settings.freq, 0.01, 1000);

    const save_btn_rect = re.rectTakeBottom(&cur_rect, 24);

    if (rg.button(save_btn_rect, "Save")) {
        try self.closeChildSettings(gpa, true);
        return;
    }
}

fn removeWire(self: *Self, gpa: Allocator, wire_key: CustomModule.WireKey) !void {
    const top_mod = self.topModPtr();
    var removed_wire = top_mod.wires.remove(wire_key).?;
    defer removed_wire.deinit(gpa);

    try globals.saveCustomModules(gpa);

    var affected = try self.top_inst.removeWire(gpa, removed_wire, self.time);
    defer if (affected) |*af| af.deinit(gpa);
}

fn removeChild(self: *Self, gpa: Allocator, child_key: Child.Key) !void {
    try self.top_inst.removeChildWithMod(gpa, child_key, self.time);
    try globals.saveCustomModules(gpa);
}

fn setInputOrder(self: *Self, input_settings: *ModuleSettings.PortSettings, new_order: usize) void {
    assert(self.mod_settings != null);

    var iter = self.mod_settings.?.inputs.cur.iterator();
    while (iter.nextValue()) |input| {
        if (input.order == new_order) {
            input.order = input_settings.order;
            break;
        }
    }

    for (self.mod_settings.?.inputs.new.items) |*input| {
        if (input.order == new_order) {
            input.order = input_settings.order;
            break;
        }
    }

    input_settings.order = new_order;
}

fn drawModSettingsMenu(self: *Self, gpa: Allocator, settings: *ModuleSettings) !void {
    rl.drawRectangle(0, 0, consts.screen_width, consts.screen_height, theme.dim);

    const rect_size: Vector2 = .init(600, consts.screen_height - 80);
    const rect_pos: Vector2 = consts.screen_size.subtract(rect_size).scale(0.5);

    const win_rect: Rectangle = re.rectFromPosSize(rect_pos, rect_size);
    const result = rg.windowBox(win_rect, "Module settings");

    if (result == 1 or rl.isKeyPressed(.enter)) {
        try self.closeModSettings(gpa, false);
        return;
    }

    const font = rl.getFontDefault() catch unreachable;

    var cur_rect: Rectangle = win_rect;
    _ = re.rectTakeTop(&cur_rect, 20); // raylib window header height
    cur_rect = re.rectPad(cur_rect, -win_pad, -win_pad);

    var name_lbl_rect = re.rectTakeTop(&cur_rect, 24);
    const delete_rect = re.rectTakeRight(&name_lbl_rect, name_lbl_rect.height);
    _ = re.rectTakeTop(&cur_rect, menu_label_space);
    const name_rect = re.rectTakeTop(&cur_rect, 40);
    _ = re.rectTakeTop(&cur_rect, menu_element_space);

    if (rg.button(delete_rect, comptimePrint("#{d}#", .{IconName.bin}))) {
        self.ctx.next_scene = .{ .selector = .{ .delete_mod = self.top_inst.mod_key } };
        try globals.saveCustomModules(gpa);
    }

    rl.drawTextEx(font, "Name:", re.rectPos(name_lbl_rect), name_lbl_rect.height, name_lbl_rect.height * 0.1, theme.text);

    if (rg.textBox(name_rect, @ptrCast(&settings.name_buf), consts.max_mod_name_size, settings.name_edit_mode))
        settings.name_edit_mode = !settings.name_edit_mode;

    const color_lbl_rect = re.rectTakeTop(&cur_rect, 24);
    const color_demo_rect: Rectangle = .init(color_lbl_rect.x + 90, color_lbl_rect.y, color_lbl_rect.height, color_lbl_rect.height);
    _ = re.rectTakeTop(&cur_rect, menu_label_space);
    const color_sel_rect = re.rectTakeTop(&cur_rect, 80);
    _ = re.rectTakeTop(&cur_rect, menu_element_space);

    rl.drawTextEx(font, "Color:", re.rectPos(color_lbl_rect), color_lbl_rect.height, color_lbl_rect.height * 0.1, theme.text);
    rl.drawRectangleRec(color_demo_rect, settings.color);
    rl.drawRectangleLinesEx(color_demo_rect, 1, theme.text_muted);
    _ = rg.colorPicker(color_sel_rect, "Color", &settings.color);

    const save_btn_rect = re.rectTakeBottom(&cur_rect, 30);
    _ = re.rectTakeBottom(&cur_rect, menu_element_space);

    if (rg.button(save_btn_rect, "Save") or rl.isKeyPressed(.enter)) {
        try self.closeModSettings(gpa, true);
        return;
    }

    var inputs_rect = re.rectTakeLeft(&cur_rect, (cur_rect.width / 2) - (menu_element_space / 2));
    _ = re.rectTakeLeft(&cur_rect, menu_element_space / 2);
    var outputs_rect = cur_rect;

    var inputs_lbl_rect = re.rectTakeTop(&inputs_rect, 30);
    _ = re.rectTakeTop(&inputs_rect, menu_label_space);
    const new_input_rect = re.rectTakeRight(&inputs_lbl_rect, 40);

    var outputs_lbl_rect = re.rectTakeTop(&outputs_rect, 30);
    _ = re.rectTakeTop(&outputs_rect, menu_label_space);
    const new_output_rect = re.rectTakeRight(&outputs_lbl_rect, 40);

    const input_cnt = settings.inputs.count();
    const output_cnt = settings.inputs.count();

    re.drawTextAligned(font, "Inputs:", re.rectAnchor(inputs_lbl_rect, .left, .center), 24, 2.4, theme.text, .left, .center);
    if (rg.button(new_input_rect, "+"))
        try settings.inputs.new.append(gpa, .init(1, input_cnt));

    re.drawTextAligned(font, "Outputs:", re.rectAnchor(outputs_lbl_rect, .left, .center), 24, 2.4, theme.text, .left, .center);
    if (rg.button(new_output_rect, "+"))
        try settings.outputs.new.append(gpa, .init(1, output_cnt));

    rl.drawRectangleLinesEx(inputs_rect, 2, theme.text_muted);
    rl.drawRectangleLinesEx(outputs_rect, 2, theme.text_muted);

    var input_iter = settings.inputs.cur.iterator();
    while (input_iter.next()) |entry| {
        const input_key = entry.key;
        const input_settings = entry.val;

        if (self.drawPortSettings(re.rectPos(inputs_rect), inputs_rect.width, input_cnt, input_settings) and self.debounce_timer == 0) {
            const removed = settings.inputs.cur.remove(input_key).?;
            settings.inputs.decreaseOrders(removed.order);
            self.debounce_timer = 5;
        }
    }

    var i: usize = 0;

    while (i < settings.inputs.new.items.len) {
        const input_settings = &settings.inputs.new.items[i];

        if (self.drawPortSettings(re.rectPos(inputs_rect), inputs_rect.width, input_cnt, input_settings) and self.debounce_timer == 0) {
            const removed = settings.inputs.new.swapRemove(i);
            settings.inputs.decreaseOrders(removed.order);
            self.debounce_timer = 5;
        } else {
            i += 1;
        }
    }

    var output_iter = settings.outputs.cur.iterator();
    while (output_iter.next()) |entry| {
        const output_key = entry.key;
        const output_settings = entry.val;

        if (self.drawPortSettings(re.rectPos(outputs_rect), outputs_rect.width, output_cnt, output_settings) and self.debounce_timer == 0) {
            const removed = settings.outputs.cur.remove(output_key).?;
            settings.outputs.decreaseOrders(removed.order);
            self.debounce_timer = 5;
        }
    }

    i = 0;

    while (i < settings.outputs.new.items.len) {
        const output_settings = &settings.outputs.new.items[i];

        if (self.drawPortSettings(re.rectPos(outputs_rect), outputs_rect.width, output_cnt, output_settings) and self.debounce_timer == 0) {
            const removed = settings.outputs.new.swapRemove(i);
            settings.outputs.decreaseOrders(removed.order);
            self.debounce_timer = 5;
        } else {
            i += 1;
        }
    }
}

fn drawPortSettings(self: *Self, base_pos: Vector2, cnt_width: f32, port_cnt: usize, port_settings: *ModuleSettings.PortSettings) bool {
    const port_spacing = 5;
    const cnt_size: Vector2 = .init(cnt_width, 45);

    const port_pos: Vector2 = .init(
        base_pos.x,
        base_pos.y + @as(f32, @floatFromInt(port_settings.order)) * (cnt_size.y + port_spacing),
    );

    const inner_space = 2;
    const move_btn_width = 35;
    const port_width_width = 55;
    const trash_btn_width = 35;

    re.guiSetEnabled(port_settings.order > 0);
    const move_up = rg.button(
        .init(port_pos.x, port_pos.y, move_btn_width, cnt_size.y / 2),
        comptimePrint("#{d}#", .{IconName.arrow_up_fill}),
    );

    if (move_up and self.debounce_timer == 0) {
        self.setInputOrder(port_settings, port_settings.order - 1);
        self.debounce_timer = 5;
    }

    re.guiSetEnabled(port_settings.order + 1 < port_cnt);
    const move_down = rg.button(
        .init(port_pos.x, port_pos.y + (cnt_size.y / 2), move_btn_width, cnt_size.y / 2),
        comptimePrint("#{d}#", .{IconName.arrow_down_fill}),
    );

    if (move_down and self.debounce_timer == 0) {
        self.setInputOrder(port_settings, port_settings.order + 1);
        self.debounce_timer = 5;
    }

    rg.enable();

    re.valueBoxT(
        usize,
        .init(port_pos.x + move_btn_width + inner_space, port_pos.y, port_width_width, cnt_size.y),
        "",
        &port_settings.width,
        consts.min_port_width,
        consts.max_port_width,
        &port_settings.width_edit_mode,
    );

    const change_edit_mode = rg.textBox(
        .init(
            port_pos.x + move_btn_width + port_width_width + (2 * inner_space),
            port_pos.y,
            cnt_size.x - move_btn_width - port_width_width - trash_btn_width - (3 * inner_space),
            cnt_size.y,
        ),
        @ptrCast(&port_settings.name_buf),
        consts.max_input_name_size,
        port_settings.name_edit_mode,
    );

    if (change_edit_mode)
        port_settings.name_edit_mode = !port_settings.name_edit_mode;

    return rg.button(
        .init(port_pos.x + cnt_size.x - trash_btn_width, port_pos.y, trash_btn_width, cnt_size.y),
        comptimePrint("#{d}#", .{IconName.bin}),
    );
}

fn openModSettings(self: *Self, gpa: Allocator) !void {
    const top_mod = self.topModPtr();

    var inputs: SecondaryMap(CustomModule.PortKey, ModuleSettings.PortSettings) = .empty;
    var input_iter = top_mod.inputs.constIterator();

    while (input_iter.next()) |entry|
        _ = try inputs.put(gpa, entry.key, .initFromPort(entry.val.*));

    var outputs: SecondaryMap(CustomModule.PortKey, ModuleSettings.PortSettings) = .empty;
    var output_iter = top_mod.outputs.constIterator();

    while (output_iter.next()) |entry|
        _ = try outputs.put(gpa, entry.key, .initFromPort(entry.val.*));

    self.mod_settings = .{
        .name_buf = undefined,
        .name_edit_mode = true,
        .color = top_mod.color,
        .inputs = .init(inputs),
        .outputs = .init(outputs),
    };

    const n = top_mod.name.len + 1;
    @memcpy(self.mod_settings.?.name_buf[0..n], top_mod.name.ptr[0..n]);
}

fn trimFixedBufferZ(comptime T: type, buf: []const T, values_to_strip: []const T) []const T {
    const len = std.mem.len(@as([*:0]const T, @ptrCast(buf[0..])));
    return std.mem.trim(T, buf[0..len], values_to_strip);
}

fn saveModSettings(self: *Self, gpa: Allocator) !void {
    assert(self.mod_settings != null);

    const top_mod = self.topModPtr();
    const settings = &self.mod_settings.?;

    const mod_name_trimmed = trimFixedBufferZ(u8, &settings.name_buf, " ");

    if (mod_name_trimmed.len != 0) {
        gpa.free(top_mod.name);
        top_mod.name = try gpa.dupeZ(u8, mod_name_trimmed);
    }

    try savePorts(gpa, settings.inputs, &self.top_inst.inputs, &top_mod.inputs);
    try savePorts(gpa, settings.outputs, &self.top_inst.outputs, &top_mod.outputs);

    top_mod.color = settings.color;

    try self.top_inst.pruneInvalidWiresWithMod(gpa, self.time);

    var mods_iter = globals.modules.iterator();
    while (mods_iter.nextValue()) |mod|
        mod.pruneInvalidWires(gpa);
}

fn savePorts(gpa: Allocator, ports: ModuleSettings.PortSettingsContainers, port_insts: *SecondaryMap(CustomModule.PortKey, []bool), dest: *SlotMap(CustomModule.Port)) !void {
    var port_iter = dest.iterator();

    while (port_iter.next()) |entry| {
        const port_key = entry.key;
        const port = entry.val;

        const port_settings = ports.cur.get(port_key) orelse {
            var removed = dest.remove(port_key).?;
            defer removed.deinit(gpa);
            continue;
        };

        if (port.name) |name|
            gpa.free(name);

        const name_trimmed = trimFixedBufferZ(u8, &port_settings.name_buf, " ");

        if (name_trimmed.len == 0) {
            port.name = null;
        } else {
            port.name = try gpa.dupeZ(u8, name_trimmed);
        }

        port.order = port_settings.order;

        if (port.width != port_settings.width) {
            port.width = port_settings.width;

            const port_values = port_insts.getPtr(port_key).?;
            gpa.free(port_values.*);

            port_values.* = try gpa.alloc(bool, port.width);
            @memset(port_values.*, false);
        }
    }

    for (ports.new.items) |port_settings| {
        const name_trimmed = trimFixedBufferZ(u8, &port_settings.name_buf, " ");

        const new_port: CustomModule.Port = .{
            .name = if (name_trimmed.len != 0) try gpa.dupeZ(u8, name_trimmed) else null,
            .width = port_settings.width,
            .order = port_settings.order,
        };
        const new_port_key = try dest.put(gpa, new_port);

        const new_port_values = try gpa.alloc(bool, port_settings.width);
        @memset(new_port_values, false);

        _ = try port_insts.put(gpa, new_port_key, new_port_values);
    }
}

fn closeModSettings(self: *Self, gpa: Allocator, save: bool) !void {
    assert(self.mod_settings != null);

    if (save) {
        try self.saveModSettings(gpa);
        try globals.saveCustomModules(gpa);
    }

    self.mod_settings.?.deinit(gpa);
    self.mod_settings = null;
}

fn closeChildSettings(self: *Self, gpa: Allocator, save: bool) !void {
    const top_mod = self.topModPtr();
    var settings = self.child_settings orelse unreachable;
    defer settings.v.deinit(gpa);
    self.child_settings = null;

    if (save) {
        const child = top_mod.children.getPtr(settings.child_key).?;

        switch (settings.v) {
            .logic_gate => saveLogicGateSettings(&child.mod.logic_gate, settings.v.logic_gate),
            .split => saveSplitSettings(&child.mod.split, settings.v.split),
            .join => try saveJoinSettings(gpa, &child.mod.join, settings.v.join),
            .clock => saveClockSettings(&child.mod.clock, settings.v.clock),
        }

        try self.top_inst.pruneInvalidWiresWithMod(gpa, self.time);
        try globals.saveCustomModules(gpa);

        try self.top_inst.reinstantiateChild(gpa, settings.child_key, self.time);
    }
}

fn saveLogicGateSettings(gate: *Module.LogicGate, new: Module.LogicGateSettings) void {
    gate.single_wire = new.single_wire;
    gate.input_cnt = new.input_cnt;
}

fn saveSplitSettings(split: *Module.Split, new: Module.SplitSettings) void {
    split.input_width = new.input_width;
    split.output_from = new.output_from;
    split.output_to = new.output_to;
}

fn saveJoinSettings(gpa: Allocator, join: *Module.Join, new: Module.JoinSettings) !void {
    gpa.free(join.inputs);
    join.inputs = try gpa.alloc(usize, new.inputs.items.len);

    for (0.., new.inputs.items) |i, s|
        join.inputs[i] = s.width;
}

fn saveClockSettings(clock: *Module.Clock, new: Module.ClockSettings) void {
    clock.freq = new.freq;
}

fn drawTopBar(self: *Self, gpa: Allocator) !void {
    const top_mod = self.topModPtr();

    if (rg.button(.init(15, 10, 40, 40), comptimePrint("#{d}#", .{IconName.arrow_left})))
        self.ctx.next_scene = .{ .selector = .{ .delete_mod = null } };

    if (rg.button(.init(65, 10, 40, 40), comptimePrint("#{d}#", .{IconName.tools})))
        try self.openModSettings(gpa);

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

const btn_height = panel_rect.height - 28;

fn bottomButton(label: [:0]const u8, pos: *Vector2) bool {
    const measure: f32 = @floatFromInt(rl.measureText(label, consts.font_size));
    const btn_width = 20 + measure;

    const result = rg.button(.init(pos.x, pos.y, btn_width, btn_height), label);
    pos.x += btn_width + (2 * btn_spacing);
    return result;
}

fn childClampBounds(gpa: Allocator, child: Child) !struct { Vector2, Vector2 } {
    const bounds = try childBounds(gpa, child);
    return .{
        .init(sim_rect.x, sim_rect.y),
        .init(
            sim_rect.x + sim_rect.width - bounds.width,
            sim_rect.y + sim_rect.height - bounds.height,
        ),
    };
}

fn addChild(self: *Self, gpa: Allocator, child_v: Module) !void {
    const top_mod = self.topModPtr();

    var child: Child = .init(consts.screen_size.scale(0.5), child_v);
    const clamp_bounds = try childClampBounds(gpa, child);

    while (containsChildWithPos(top_mod.children, child.pos)) {
        const new_pos = child.pos.addValue(25).clamp(clamp_bounds[0], clamp_bounds[1]);
        if (child.pos.equals(new_pos) != 0)
            break;

        child.pos = new_pos;
    }

    const child_key = try top_mod.children.put(gpa, child);
    try globals.saveCustomModules(gpa);

    try self.top_inst.addChild(gpa, child_key, self.time);
    self.selection = .{ .child = child_key };
}

fn drawBottomPanel(self: *Self, gpa: Allocator) !void {
    const panel_contents: Rectangle = .init(panel_rect.x, panel_rect.y + 2, self.panel_contents_width, panel_rect.height - 16);
    const panel_base = re.rectPos(panel_contents);

    _ = rg.scrollPanel(panel_rect, null, panel_contents, &self.panel_scroll, &self.panel_view);

    re.beginScissorModeRec(self.panel_view);
    defer rl.endScissorMode();

    var btn_pos = panel_base.addValue(btn_spacing).add(self.panel_scroll);

    for (std.enums.values(Module.LogicGate.Kind)) |kind| {
        if (bottomButton(@tagName(kind), &btn_pos))
            try self.addChild(gpa, .{ .logic_gate = .init(kind) });
    }

    if (bottomButton("not", &btn_pos))
        try self.addChild(gpa, .not_gate);

    if (bottomButton("split", &btn_pos))
        try self.addChild(gpa, .{ .split = .init(4, 0, 1) });

    if (bottomButton("join", &btn_pos))
        try self.addChild(gpa, .{ .join = try .init(gpa, &.{ 2, 2 }) });

    if (bottomButton("clock", &btn_pos))
        try self.addChild(gpa, .{ .clock = .init(1) });

    var iter = globals.modules.constIterator();
    while (iter.next()) |entry| {
        const mod = entry.val;

        re.guiSetEnabled(!self.disabled_modules.contains(entry.key));
        defer rg.enable();

        if (bottomButton(mod.name, &btn_pos))
            try self.addChild(gpa, .{ .custom = entry.key });
    }
    if (self.panel_contents_width == 0)
        self.panel_contents_width = btn_pos.x - (2 * btn_spacing);
}

fn containsChildWithPos(children: SlotMap(Child), pos: Vector2) bool {
    var iter = children.constIterator();
    while (iter.nextValue()) |child| {
        if (child.pos.distanceSqr(pos) < consts.epsilon_sqr)
            return true;
    }

    return false;
}

fn drawWire(self: Self, gpa: Allocator, wire: Wire, highlight: bool) !void {
    const wire_values = self.top_inst.readWireSrc(wire.from);
    const from_pos = try self.wireSrcPos(gpa, wire.from);
    const to_pos = try self.wireDestPos(gpa, wire.to);

    if (highlight)
        drawWireLines(from_pos, to_pos, wire.points, 3 * wire_thick, theme.selection_border);

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

fn drawTopInput(self: Self, gpa: Allocator, input_key: CustomModule.PortKey, hover: HoverInfo) !void {
    const input = self.topModPtr().inputs.get(input_key).?;
    const values = self.top_inst.inputs.get(input_key).?;

    const btn_pos = self.topInputBtnPos(input_key);
    const pin_pos = self.topInputPosPin(input_key);

    rl.drawLineEx(btn_pos, pin_pos, 8, theme.port);
    rl.drawCircleV(btn_pos, top_port_radius_btn, logicColor(values));

    const highlight_port = hover == .top_input_pin and hover.top_input_pin.equals(input_key);
    try drawPort(gpa, pin_pos, highlight_port, input.width);
}

fn drawTopOutput(self: Self, gpa: Allocator, output_key: CustomModule.PortKey, hover: HoverInfo) !void {
    const output = self.topModPtr().outputs.get(output_key).?;
    const value = self.top_inst.outputs.get(output_key).?;

    const btn_pos = self.topOutputPosBtn(output_key);
    const pin_pos = self.topOutputPinPos(output_key);

    rl.drawLineEx(btn_pos, pin_pos, 8, theme.port);
    rl.drawCircleV(btn_pos, top_port_radius_btn, logicColor(value));

    const highlight_port = hover == .top_output_pin and hover.top_output_pin.equals(output_key);
    try drawPort(gpa, pin_pos, highlight_port, output.width);
}

fn drawSimulation(self: *Self, gpa: Allocator, mouse: Vector2, hover: HoverInfo) !void {
    rl.drawRectangleLinesEx(sim_rect, 2, theme.text_muted);

    re.beginScissorModeRec(sim_rect);
    defer rl.endScissorMode();

    const top_mod = self.topModPtr();

    var wire_iter = top_mod.wires.constIterator();
    while (wire_iter.next()) |entry| {
        const highlight = self.selection == .wire and self.selection.wire.equals(entry.key);
        try self.drawWire(gpa, entry.val.*, highlight);
    }

    const snapped_mouse = try self.snapMouse(gpa, mouse);

    switch (self.mouse_action) {
        .wire_from => |from| {
            const from_value = self.top_inst.readWireSrc(from);
            const from_pos = try self.wireSrcPos(gpa, from);
            drawWireLines(from_pos, snapped_mouse, self.wire_points.items, wire_thick, logicColor(from_value));
        },
        .wire_to => |to| {
            const to_pos = try self.wireDestPos(gpa, to);
            drawWireLines(to_pos, snapped_mouse, self.wire_points.items, wire_thick, logicColor(&.{false}));
        },
        else => {},
    }

    var input_iter = top_mod.inputs.constIterator();
    while (input_iter.nextKey()) |input_key|
        try self.drawTopInput(gpa, input_key, hover);

    var output_iter = top_mod.outputs.constIterator();
    while (output_iter.nextKey()) |output_key|
        try self.drawTopOutput(gpa, output_key, hover);

    var child_iter = top_mod.children.constIterator();
    while (child_iter.nextKey()) |child_key|
        try self.drawChild(gpa, child_key, hover);
}

fn snapMouse(self: Self, gpa: Allocator, mouse: Vector2) !Vector2 {
    if (!rl.isKeyDown(.left_shift))
        return mouse;

    switch (self.mouse_action) {
        .wire_from => |from| {
            const from_pos = try self.wireSrcPos(gpa, from);
            const last_point = self.wire_points.getLastOrNull() orelse from_pos;
            return math.snap(last_point, mouse);
        },
        .wire_to => |to| {
            const to_pos = try self.wireDestPos(gpa, to);
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

fn logicGateBounds(pos: Vector2, gate: Module.LogicGate) Rectangle {
    if (gate.single_wire)
        return moduleRectangle(pos, @tagName(gate.kind), 1);

    return moduleRectangle(pos, @tagName(gate.kind), gate.input_cnt);
}

fn notGateBounds(pos: Vector2) Rectangle {
    return moduleRectangle(pos, "not", 1);
}

fn splitBounds(gpa: Allocator, split: Module.Split, pos: Vector2) !Rectangle {
    const range_str = try split.allocFmtRange(gpa);
    defer gpa.free(range_str);

    return moduleRectangle(pos, range_str, 1);
}

fn joinBounds(join: Module.Join, pos: Vector2) Rectangle {
    return moduleRectangle(pos, "join", join.inputs.len);
}

fn clockBounds(gpa: Allocator, clock: Module.Clock, pos: Vector2) !Rectangle {
    const range_str = try clock.allocFmtFreq(gpa);
    defer gpa.free(range_str);

    return moduleRectangle(pos, range_str, 1);
}

fn customModuleBounds(pos: Vector2, module: CustomModule) Rectangle {
    return moduleRectangle(
        pos,
        module.name,
        @max(module.inputs.count, module.outputs.count),
    );
}

fn childBounds(gpa: Allocator, child: Child) !Rectangle {
    return switch (child.mod) {
        .logic_gate => |gate| logicGateBounds(child.pos, gate),
        .not_gate => notGateBounds(child.pos),
        .split => |split| try splitBounds(gpa, split, child.pos),
        .join => |join| joinBounds(join, child.pos),
        .clock => |clock| try clockBounds(gpa, clock, child.pos),
        .custom => |mod_key| customModuleBounds(child.pos, globals.modules.get(mod_key).?),
    };
}

const selection_pad = 8;

fn drawLogicGate(gpa: Allocator, gate: Module.LogicGate, pos: Vector2, hovered_input: bool, hovered_output: bool, hover: HoverInfo, selected: bool) !void {
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
        rl.drawRectangleRec(re.rectPad(bounds, selection_pad, selection_pad), theme.selection_border);

    rl.drawRectangleRec(bounds, color);
    re.drawTextAligned(font, @tagName(gate.kind), bounds_center, consts.font_size, consts.font_spacing, theme.text, .center, .center);

    if (gate.single_wire) {
        try drawPort(gpa, logicGateInputSingleWirePos(gate, pos), hovered_input, gate.input_cnt);
    } else {
        for (0..gate.input_cnt) |input| {
            const highlight = hovered_input and hover.child_input.input.logic_gate == input;
            drawPortNoWidth(logicGateInputPos(gate, pos, input), highlight);
        }
    }

    drawPortNoWidth(logicGateOutputPos(gate, pos), hovered_output);
}

fn drawNotGate(pos: Vector2, hovered_input: bool, hovered_output: bool, selected: bool) void {
    const font = rl.getFontDefault() catch unreachable;
    const bounds = notGateBounds(pos);
    const bounds_center = re.rectCenter(bounds);

    if (selected)
        rl.drawRectangleRec(re.rectPad(bounds, selection_pad, selection_pad), theme.selection_border);

    rl.drawRectangleRec(bounds, theme.not_gate);
    re.drawTextAligned(font, "not", bounds_center, consts.font_size, consts.font_spacing, theme.text, .center, .center);

    drawPortNoWidth(notGateInputPos(pos), hovered_input);
    drawPortNoWidth(notGateOutputPos(pos), hovered_output);
}

fn drawPortNoWidth(pos: Vector2, hover: bool) void {
    rl.drawCircleV(pos, port_radius, if (hover) theme.background_alt else theme.port);
}

fn drawPort(gpa: Allocator, pos: Vector2, hover: bool, width: usize) !void {
    drawPortNoWidth(pos, hover);

    if (width != 1) {
        const width_str = try allocPrintSentinel(gpa, "{d}", .{width}, 0);
        defer gpa.free(width_str);

        const font = rl.getFontDefault() catch unreachable;
        re.drawTextAligned(font, width_str, pos, 16, 1.6, theme.text_muted, .center, .center);
    }
}

fn drawSplit(gpa: Allocator, split: Module.Split, pos: Vector2, hovered_input: bool, hovered_output: bool, selected: bool) !void {
    const font = rl.getFontDefault() catch unreachable;
    const bounds = try splitBounds(gpa, split, pos);
    const bounds_center = re.rectCenter(bounds);

    if (selected)
        rl.drawRectangleRec(re.rectPad(bounds, selection_pad, selection_pad), theme.selection_border);

    rl.drawRectangleRec(bounds, theme.split);

    const range_str = try split.allocFmtRange(gpa);
    defer gpa.free(range_str);

    re.drawTextAligned(font, range_str, bounds_center, consts.font_size, consts.font_spacing, theme.text, .center, .center);

    try drawPort(gpa, try splitInputPos(gpa, split, pos), hovered_input, split.input_width);
    try drawPort(gpa, try splitOutputPos(gpa, split, pos), hovered_output, split.outputWidth());
}

fn drawJoin(gpa: Allocator, join: Module.Join, pos: Vector2, hovered_input: bool, hovered_output: bool, hover: HoverInfo, selected: bool) !void {
    const font = rl.getFontDefault() catch unreachable;
    const bounds = joinBounds(join, pos);
    const bounds_center = re.rectCenter(bounds);

    if (selected)
        rl.drawRectangleRec(re.rectPad(bounds, selection_pad, selection_pad), theme.selection_border);

    rl.drawRectangleRec(bounds, theme.join);
    re.drawTextAligned(font, "join", bounds_center, consts.font_size, consts.font_spacing, theme.text, .center, .center);

    for (0..join.inputs.len) |input_idx| {
        const highlight = hovered_input and hover.child_input.input.join == input_idx;
        try drawPort(gpa, joinInputPos(join, pos, input_idx), highlight, join.inputs[input_idx]);
    }

    try drawPort(gpa, joinOutputPos(join, pos), hovered_output, join.outputWidth());
}

fn drawClock(gpa: Allocator, clock: Module.Clock, pos: Vector2, hovered_output: bool, selected: bool) !void {
    const font = rl.getFontDefault() catch unreachable;
    const bounds = try clockBounds(gpa, clock, pos);
    const bounds_center = re.rectCenter(bounds);

    if (selected)
        rl.drawRectangleRec(re.rectPad(bounds, selection_pad, selection_pad), theme.selection_border);

    rl.drawRectangleRec(bounds, theme.clock);

    const freq_str = try clock.allocFmtFreq(gpa);
    defer gpa.free(freq_str);

    re.drawTextAligned(font, freq_str, bounds_center, consts.font_size, consts.font_spacing, theme.text, .center, .center);
    drawPortNoWidth(try clockOutputPos(gpa, clock, pos), hovered_output);
}

fn drawCustomModule(gpa: Allocator, mod_key: CustomModule.Key, pos: Vector2, hovered_input: bool, hovered_output: bool, hover: HoverInfo, selected: bool) !void {
    const font = rl.getFontDefault() catch unreachable;
    const mod = globals.modules.get(mod_key).?;
    const bounds = customModuleBounds(pos, mod);
    const bounds_center = re.rectCenter(bounds);

    if (selected)
        rl.drawRectangleRec(re.rectPad(bounds, selection_pad, selection_pad), theme.selection_border);

    rl.drawRectangleRec(bounds, mod.color);

    var input_iter = mod.inputs.constIterator();
    while (input_iter.next()) |entry| {
        const input_key = entry.key;
        const input = entry.val;

        const highlight = hovered_input and hover.child_input.input.custom.equals(input_key);
        try drawPort(gpa, customModuleInputPos(mod, pos, input_key), highlight, input.width);
    }

    var output_iter = mod.outputs.constIterator();
    while (output_iter.next()) |entry| {
        const output_key = entry.key;
        const output = entry.val;

        const highlight = hovered_output and hover.child_output.output.custom.equals(output_key);
        try drawPort(gpa, customModuleOutputPos(mod, pos, output_key), highlight, output.width);
    }

    re.drawTextAligned(font, mod.name, bounds_center, consts.font_size, consts.font_spacing, theme.text, .center, .center);
}

fn drawChild(self: *Self, gpa: Allocator, child_key: Child.Key, hover: HoverInfo) !void {
    const top_mod = self.topModPtr();
    const child = top_mod.children.get(child_key).?;

    const selected = self.selection == .child and self.selection.child.equals(child_key);

    // All module kinds use this to draw a rect, at least for now.
    const hovered_input = hover == .child_input and hover.child_input.child_key.equals(child_key);
    const hovered_output = hover == .child_output and hover.child_output.child_key.equals(child_key);

    switch (child.mod) {
        .logic_gate => |gate| try drawLogicGate(gpa, gate, child.pos, hovered_input, hovered_output, hover, selected),
        .not_gate => drawNotGate(child.pos, hovered_input, hovered_output, selected),
        .split => |split| try drawSplit(gpa, split, child.pos, hovered_input, hovered_output, selected),
        .join => |join| try drawJoin(gpa, join, child.pos, hovered_input, hovered_output, hover, selected),
        .clock => |clock| try drawClock(gpa, clock, child.pos, hovered_output, selected),
        .custom => |mod_key| try drawCustomModule(gpa, mod_key, child.pos, hovered_input, hovered_output, hover, selected),
    }
}

fn openChildSettings(self: *Self, gpa: Allocator, child_key: Child.Key) !void {
    const child = self.topModPtr().children.get(child_key).?;

    if (child.mod.hasSettings()) {
        self.child_settings = .{
            .child_key = child_key,
            .v = try child.mod.currentSettings(gpa),
        };
    }
}

fn addWire(self: *Self, gpa: Allocator, wire: Wire) !void {
    const top_mod = self.topModPtr();

    // Only create wire if port widths match
    if (top_mod.wireSrcWidth(wire.from) == top_mod.wireDestWidth(wire.to)) {
        const new_wire_key = try top_mod.addWireOrModifyExisting(gpa, wire);
        try self.top_inst.addWire(gpa, new_wire_key, self.time);

        self.selection = .{ .wire = new_wire_key };
        try globals.saveCustomModules(gpa);
    }

    self.mouse_action = .none;
}

// TODO: this sucks
fn onClick(self: *Self, gpa: Allocator, hover: HoverInfo, mouse: Vector2) !void {
    const top_mod = self.topModPtr();
    const snapped_mouse = try self.snapMouse(gpa, mouse);

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
                    const input = self.top_inst.inputs.get(input_key).?;
                    const new_values = try gpa.alloc(bool, input.len);
                    defer gpa.free(new_values);

                    for (0.., input) |i, v|
                        new_values[i] = !v;

                    try self.top_inst.writeInput(gpa, input_key, new_values, self.time);
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

fn onDoubleClick(self: *Self, gpa: Allocator, hover: HoverInfo) !void {
    switch (hover) {
        .child => |child_key| {
            try self.openChildSettings(gpa, child_key);
            self.mouse_action = .none;
        },
        else => {},
    }
}

fn onRightClick(self: *Self) void {
    switch (self.mouse_action) {
        .wire_from, .wire_to => self.mouse_action = .none,
        else => {},
    }
}

fn onUnclick(self: *Self, gpa: Allocator) !void {
    if (self.mouse_action == .drag_module) {
        self.mouse_action = .none;
        try globals.saveCustomModules(gpa);
    }
}

fn getHoverInfo(self: Self, gpa: Allocator, mouse: Vector2) !HoverInfo {
    if (self.mod_settings != null or self.child_settings != null)
        return .none;

    const top_mod = self.topModPtr();

    var input_iter = top_mod.inputs.constIterator();
    while (input_iter.nextKey()) |input_key| {
        if (mouse.distance(self.topInputBtnPos(input_key)) <= top_port_radius_btn)
            return .{ .top_input_btn = input_key };

        if (mouse.distance(self.topInputPosPin(input_key)) <= port_radius)
            return .{ .top_input_pin = input_key };
    }

    var output_iter = top_mod.outputs.constIterator();
    while (output_iter.nextKey()) |output_key| {
        if (mouse.distance(self.topOutputPinPos(output_key)) <= port_radius)
            return .{ .top_output_pin = output_key };
    }

    var child_iter = top_mod.children.revIterator();

    while (child_iter.next()) |entry| {
        const child = entry.val;

        switch (child.mod) {
            .logic_gate => |gate| {
                if (gate.single_wire) {
                    const input_pos = logicGateInputSingleWirePos(gate, child.pos);

                    if (mouse.distance(input_pos) <= port_radius) {
                        return .{
                            .child_input = .{
                                .child_key = entry.key,
                                .input = .{ .logic_gate = null },
                            },
                        };
                    }
                } else {
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
            .split => |split| {
                const input_pos = try splitInputPos(gpa, split, child.pos);
                const output_pos = try splitOutputPos(gpa, split, child.pos);

                if (mouse.distance(input_pos) <= port_radius) {
                    return .{
                        .child_input = .{
                            .child_key = entry.key,
                            .input = .split,
                        },
                    };
                }

                if (mouse.distance(output_pos) <= port_radius) {
                    return .{
                        .child_output = .{
                            .child_key = entry.key,
                            .output = .split,
                        },
                    };
                }
            },
            .join => |join| {
                for (0..join.inputs.len) |input_idx| {
                    const input_pos = joinInputPos(join, child.pos, input_idx);
                    if (mouse.distance(input_pos) <= port_radius) {
                        return .{
                            .child_input = .{
                                .child_key = entry.key,
                                .input = .{ .join = input_idx },
                            },
                        };
                    }
                }

                const output_pos = joinOutputPos(join, child.pos);
                if (mouse.distance(output_pos) <= port_radius) {
                    return .{
                        .child_output = .{
                            .child_key = entry.key,
                            .output = .join,
                        },
                    };
                }
            },
            .clock => |clock| {
                const output_pos = try clockOutputPos(gpa, clock, child.pos);
                if (mouse.distance(output_pos) <= port_radius) {
                    return .{
                        .child_output = .{
                            .child_key = entry.key,
                            .output = .clock,
                        },
                    };
                }
            },
            .custom => |mod_key| {
                const child_mod = globals.modules.get(mod_key).?;

                input_iter = child_mod.inputs.constIterator();
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

                output_iter = child_mod.outputs.constIterator();
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

        const bounds = try childBounds(gpa, child.*);

        if (math.checkVec2RectCollision(mouse, bounds))
            return .{ .child = entry.key };
    }

    var wire_iter = top_mod.wires.constIterator();

    while (wire_iter.next()) |entry| {
        const wire = entry.val;
        const from_pos = try self.wireSrcPos(gpa, wire.from);
        const to_pos = try self.wireDestPos(gpa, wire.to);

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

fn logicGateInputPos(gate: Module.LogicGate, base_pos: Vector2, input: usize) Vector2 {
    assert(!gate.single_wire);
    const bounds = logicGateBounds(base_pos, gate);
    const y_offset = math.interpolate(gate.input_cnt, input, bounds.height + (2 * port_radius));

    return .init(base_pos.x, base_pos.y - port_radius + y_offset);
}

fn logicGateInputSingleWirePos(gate: Module.LogicGate, base_pos: Vector2) Vector2 {
    assert(gate.single_wire);
    const bounds = logicGateBounds(base_pos, gate);
    return re.rectAnchor(bounds, .left, .center);
}

fn logicGateOutputPos(gate: Module.LogicGate, base_pos: Vector2) Vector2 {
    const bounds = logicGateBounds(base_pos, gate);
    return re.rectAnchor(bounds, .right, .center);
}

fn notGateInputPos(base_pos: Vector2) Vector2 {
    const bounds = notGateBounds(base_pos);
    return re.rectAnchor(bounds, .left, .center);
}

fn notGateOutputPos(base_pos: Vector2) Vector2 {
    const bounds = notGateBounds(base_pos);
    return re.rectAnchor(bounds, .right, .center);
}

fn splitInputPos(gpa: Allocator, split: Module.Split, base_pos: Vector2) !Vector2 {
    const bounds = try splitBounds(gpa, split, base_pos);
    return re.rectAnchor(bounds, .left, .center);
}

fn splitOutputPos(gpa: Allocator, split: Module.Split, base_pos: Vector2) !Vector2 {
    const bounds = try splitBounds(gpa, split, base_pos);
    return re.rectAnchor(bounds, .right, .center);
}

fn joinInputPos(join: Module.Join, base_pos: Vector2, input: usize) Vector2 {
    const bounds = joinBounds(join, base_pos);
    const y_offset = math.interpolate(join.inputs.len, input, bounds.height + (2 * port_radius));

    return .init(base_pos.x, base_pos.y - port_radius + y_offset);
}

fn joinOutputPos(join: Module.Join, base_pos: Vector2) Vector2 {
    const bounds = joinBounds(join, base_pos);
    return re.rectAnchor(bounds, .right, .center);
}

fn clockOutputPos(gpa: Allocator, clock: Module.Clock, base_pos: Vector2) !Vector2 {
    const bounds = try clockBounds(gpa, clock, base_pos);
    return .init(base_pos.x + bounds.width, base_pos.y + (bounds.height / 2));
}

fn customModuleInputPos(module: CustomModule, base_pos: Vector2, input_key: CustomModule.PortKey) Vector2 {
    const input = module.inputs.get(input_key).?;
    const bounds = customModuleBounds(base_pos, module);

    return .init(
        base_pos.x,
        base_pos.y - port_radius + math.interpolate(
            module.inputs.count,
            input.order,
            bounds.height + (2 * port_radius),
        ),
    );
}

fn customModuleOutputPos(module: CustomModule, base_pos: Vector2, output_key: CustomModule.PortKey) Vector2 {
    const bounds = customModuleBounds(base_pos, module);
    const output = module.outputs.get(output_key).?;

    return .init(
        base_pos.x + bounds.width,
        base_pos.y - port_radius + math.interpolate(
            module.outputs.count,
            output.order,
            bounds.height + (2 * port_radius),
        ),
    );
}

fn topInputBtnPos(self: Self, input_key: CustomModule.PortKey) Vector2 {
    const top_mod = self.topModPtr();
    const input = top_mod.inputs.get(input_key).?;

    return .init(
        2 * top_port_radius_btn,
        sim_rect.y - (top_port_radius_btn) + math.interpolate(
            top_mod.inputs.count,
            input.order,
            sim_rect.height + (2 * top_port_radius_btn),
        ),
    );
}

fn topInputPosPin(self: Self, input_key: CustomModule.PortKey) Vector2 {
    return self.topInputBtnPos(input_key).add(.init(top_port_btn_pin_distance, 0));
}

fn topOutputPosBtn(self: Self, output_key: CustomModule.PortKey) Vector2 {
    const top_mod = self.topModPtr();
    const output = top_mod.outputs.get(output_key).?;

    return .init(
        consts.screen_width - (2 * top_port_radius_btn),
        sim_rect.y - (top_port_radius_btn) + math.interpolate(
            top_mod.outputs.count,
            output.order,
            sim_rect.height + (2 * top_port_radius_btn),
        ),
    );
}

fn topOutputPinPos(self: Self, output_key: CustomModule.PortKey) Vector2 {
    const btn_pos = self.topOutputPosBtn(output_key);
    return btn_pos.subtract(.init(top_port_btn_pin_distance, 0));
}

fn wireSrcPos(self: Self, gpa: Allocator, src: WireSrc) !Vector2 {
    switch (src) {
        .top_input => |input_key| return self.topInputPosPin(input_key),
        .child_output => |ref| {
            const child = self.topModPtr().children.get(ref.child_key).?;
            return switch (child.mod) {
                .logic_gate => |gate| logicGateOutputPos(gate, child.pos),
                .not_gate => notGateOutputPos(child.pos),
                .split => |split| try splitOutputPos(gpa, split, child.pos),
                .join => |join| joinOutputPos(join, child.pos),
                .clock => |clock| try clockOutputPos(gpa, clock, child.pos),
                .custom => |key| customModuleOutputPos(globals.modules.get(key).?, child.pos, ref.output.custom),
            };
        },
    }
}

fn wireDestPos(self: Self, gpa: Allocator, dest: WireDest) !Vector2 {
    switch (dest) {
        .top_output => |output_key| return self.topOutputPinPos(output_key),
        .child_input => |ref| {
            const child = self.topModPtr().children.get(ref.child_key).?;
            return switch (child.mod) {
                .logic_gate => |gate| if (gate.single_wire) blk: {
                    assert(ref.input.logic_gate == null);
                    break :blk logicGateInputSingleWirePos(gate, child.pos);
                } else logicGateInputPos(gate, child.pos, ref.input.logic_gate.?),
                .not_gate => notGateInputPos(child.pos),
                .split => |split| try splitInputPos(gpa, split, child.pos),
                .join => |join| joinInputPos(join, child.pos, ref.input.join),
                .clock => unreachable,
                .custom => |mod_key| blk: {
                    const child_mod = globals.modules.get(mod_key).?;
                    break :blk customModuleInputPos(child_mod, child.pos, ref.input.custom);
                },
            };
        },
    }
}

fn logicColor(values: []const bool) Color {
    return if (std.mem.allEqual(bool, values, false)) theme.logic_off else theme.logic_on;
}

fn topModPtr(self: Self) *CustomModule {
    return globals.modules.getPtr(self.top_inst.mod_key).?;
}
