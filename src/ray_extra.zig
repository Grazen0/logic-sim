const rl = @import("raylib");
const rg = @import("raygui");

const Color = rl.Color;
const Font = rl.Font;
const Vector2 = rl.Vector2;
const Rectangle = rl.Rectangle;

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

pub fn rectPad(rect: Rectangle, padding: f32) Rectangle {
    return .init(
        rect.x - padding,
        rect.y - padding,
        rect.width + (2 * padding),
        rect.height + (2 * padding),
    );
}

pub fn rectCenter(rect: Rectangle) Vector2 {
    return .init(
        rect.x + (rect.width / 2),
        rect.y + (rect.height / 2),
    );
}
