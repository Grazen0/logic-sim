const rl = @import("raylib");
const rg = @import("raygui");
const theme = @import("./theme.zig");

const Color = rl.Color;
const Font = rl.Font;
const Vector2 = rl.Vector2;
const Rectangle = rl.Rectangle;
const IconName = rg.IconName;

pub const HorizontalAlignment = enum { left, center, right };
pub const VerticalAlignment = enum { top, center, bottom };

pub fn drawTextAligned(
    font: Font,
    text: [:0]const u8,
    position: Vector2,
    fontSize: f32,
    spacing: f32,
    tint: Color,
    align_x: HorizontalAlignment,
    align_y: VerticalAlignment,
) void {
    const text_size = rl.measureTextEx(font, text, fontSize, spacing);

    const aligned_x = switch (align_x) {
        .left => position.x,
        .center => position.x - (text_size.x / 2),
        .right => position.x - text_size.x,
    };

    const aligned_y = switch (align_y) {
        .top => position.y,
        .center => position.y - (text_size.y / 2),
        .bottom => position.y - text_size.y,
    };

    rl.drawTextEx(
        font,
        text,
        .init(aligned_x, aligned_y),
        fontSize,
        spacing,
        tint,
    );
}

pub fn guiSetEnabled(enabled: bool) void {
    if (enabled) {
        rg.enable();
    } else {
        rg.disable();
    }
}

pub fn beginScissorModeRec(rect: Rectangle) void {
    rl.beginScissorMode(
        @intFromFloat(rect.x),
        @intFromFloat(rect.y),
        @intFromFloat(rect.width),
        @intFromFloat(rect.height),
    );
}

pub fn rectPad(rect: Rectangle, pad_x: f32, pad_y: f32) Rectangle {
    return .init(rect.x - pad_x, rect.y - pad_y, rect.width + (2 * pad_x), rect.height + (2 * pad_y));
}

pub fn rectWithCenter(center: Vector2, size: Vector2) Rectangle {
    return .init(center.x - (size.x / 2), center.y - (size.y / 2), size.x, size.y);
}

pub fn rectPos(rect: Rectangle) Vector2 {
    return .init(rect.x, rect.y);
}

pub fn rectSize(rect: Rectangle) Vector2 {
    return .init(rect.width, rect.height);
}

pub fn rectCenter(rect: Rectangle) Vector2 {
    return .init(rect.x + (rect.width / 2), rect.y + (rect.height / 2));
}

pub fn rectFromPosSize(pos: Vector2, size: Vector2) Rectangle {
    return .init(pos.x, pos.y, size.x, size.y);
}

pub fn rectFromTo(from: Vector2, to: Vector2) Rectangle {
    return .init(from.x, from.y, to.x - from.x, to.y - from.y);
}

pub fn rectTakeTop(rect: *Rectangle, height: f32) Rectangle {
    const taken: Rectangle = .init(rect.x, rect.y, rect.width, height);
    rect.y += height;
    rect.height -= height;
    return taken;
}

pub fn rectTakeBottom(rect: *Rectangle, height: f32) Rectangle {
    rect.height -= height;
    return .init(rect.x, rect.y + rect.height, rect.width, height);
}

pub fn rectTakeLeft(rect: *Rectangle, width: f32) Rectangle {
    const taken: Rectangle = .init(rect.x, rect.y, width, rect.height);
    rect.x += width;
    rect.width -= width;
    return taken;
}

pub fn rectTakeRight(rect: *Rectangle, width: f32) Rectangle {
    rect.width -= width;
    return .init(rect.x + rect.width, rect.y, width, rect.height);
}

pub fn rectAnchor(rect: Rectangle, h_align: HorizontalAlignment, v_align: VerticalAlignment) Vector2 {
    const x = switch (h_align) {
        .left => rect.x,
        .center => rect.x + (rect.width / 2),
        .right => rect.x + rect.width,
    };

    const y = switch (v_align) {
        .top => rect.y,
        .center => rect.y + (rect.height / 2),
        .bottom => rect.y + rect.height,
    };

    return .init(x, y);
}

pub fn valueBoxT(comptime T: type, bounds: Rectangle, text: [:0]const u8, value: *T, min: T, max: T, edit_mode: *bool) void {
    var value_i32: i32 = @intCast(value.*);
    const result = rg.valueBox(bounds, text, &value_i32, @intCast(min), @intCast(max), edit_mode.*);
    value.* = @intCast(value_i32);

    if (result != 0)
        edit_mode.* = !edit_mode.*;
}

pub fn valueBoxFloat(bounds: Rectangle, text: [:0]const u8, text_value: [:0]u8, value: *f32, edit_mode: *bool) void {
    if (rg.valueBoxFloat(bounds, text, text_value, value, edit_mode.*) != 0)
        edit_mode.* = !edit_mode.*;
}

pub fn dropdownBoxEx(bounds: Rectangle, text: [:0]const u8, active: *i32, edit_mode: *bool) void {
    if (rg.dropdownBox(bounds, text, active, edit_mode.*) != 0)
        edit_mode.* = !edit_mode.*;
}

pub fn drawIconEx(icon_id: IconName, pos: Vector2, pixel_size: i32, color: Color) void {
    rg.drawIcon(@intFromEnum(icon_id), @intFromFloat(pos.x), @intFromFloat(pos.y), pixel_size, color);
}

pub fn drawTooltip(text: [:0]const u8) void {
    const font_size = 28;
    const font = rl.getFontDefault() catch unreachable;
    const size = rl.measureTextEx(font, text, font_size, font_size * 0.1).add(.init(24, 8));

    const mouse = rl.getMousePosition();

    const rect = rectFromPosSize(mouse.subtract(.init(0, size.y)), size);
    rl.drawRectangleRec(rect, theme.tooltip_bg);
    drawTextAligned(font, text, rectCenter(rect), font_size, font_size * 0.1, theme.text, .center, .center);
}

pub fn drawLineRounded(start: Vector2, end: Vector2, thick: f32, color: Color) void {
    rl.drawLineEx(start, end, thick, color);
    rl.drawCircleV(start, thick / 2, color);
    rl.drawCircleV(end, thick / 2, color);
}
