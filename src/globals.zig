const rl = @import("raylib");

const Color = rl.Color;
const Vector2 = rl.Vector2;
const KeyboardKey = rl.KeyboardKey;

pub const epsilon = 1e-9;

pub const max_mod_name_size = 32;

pub const screen_width = 1280;
pub const screen_height = 720;
pub const screen_size: Vector2 = .init(screen_width, screen_height);
pub const font_size = 30;
pub const font_spacing = font_size * 0.1;

pub const escape_key: KeyboardKey = .caps_lock; // TODO: set this to escape later

pub const Colorscheme = struct {
    background: Color,
    background_alt: Color,
    background_dark: Color,
    dim: Color,
    text: Color,
    text_muted: Color,

    port: Color,
    logic_on: Color,
    logic_off: Color,
};

pub const colors: Colorscheme = .{
    .background = .init(0x1F, 0x1F, 0x28, 0xFF),
    .background_alt = .init(0x2A, 0x2A, 0x37, 0xFF),
    .background_dark = .init(0x16, 0x16, 0x1D, 0xFF),
    .dim = .init(0x1F, 0x1F, 0x28, 0xC0),
    .text = .init(0xDC, 0xD7, 0xBA, 0xFF),
    .text_muted = .init(0x54, 0x54, 0x6D, 0xFF),

    .port = .black,
    .logic_on = .init(0xC3, 0x40, 0x43, 0xFF),
    .logic_off = .init(0x54, 0x54, 0x6D, 0xFF),
};
