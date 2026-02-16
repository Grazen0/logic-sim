const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");

const Color = rl.Color;
const Vector2 = rl.Vector2;
const KeyboardKey = rl.KeyboardKey;

pub const web_build = builtin.target.os.tag == .emscripten;

pub const epsilon = 1e-9;
pub const epsilon_sqr = std.math.pow(f32, epsilon, 2);

pub const max_mod_name_size = 32;

pub const screen_width = 1280;
pub const screen_height = 720;
pub const screen_size: Vector2 = .init(screen_width, screen_height);
pub const font_size = 30;
pub const font_spacing = font_size * 0.1;

// TODO: find a proper fix for caps:swapescape support
pub const escape_key: KeyboardKey = if (web_build) .escape else .caps_lock;

pub const Colorscheme = struct {
    background: Color,
    background_alt: Color,
    background_dark: Color,
    dim: Color,
    text: Color,
    text_muted: Color,
    selection_border: Color,

    port: Color,
    logic_on: Color,
    logic_off: Color,

    and_gate: Color,
    nand_gate: Color,
    or_gate: Color,
    nor_gate: Color,
    xor_gate: Color,
    not_gate: Color,
};

pub const colors: Colorscheme = .{
    .background = .init(0x1F, 0x1F, 0x28, 0xFF),
    .background_alt = .init(0x2A, 0x2A, 0x37, 0xFF),
    .background_dark = .init(0x16, 0x16, 0x1D, 0xFF),
    .dim = .init(0x1F, 0x1F, 0x28, 0xC0),
    .text = .init(0xDC, 0xD7, 0xBA, 0xFF),
    .text_muted = .init(0x54, 0x54, 0x6D, 0xFF),
    .selection_border = .init(0x00, 0x00, 0x00, 0x80),

    .port = .black,
    .logic_on = .init(0xC3, 0x40, 0x43, 0xFF),
    .logic_off = .init(0x54, 0x54, 0x6D, 0xFF),

    .and_gate = .init(0x7E, 0x9C, 0xD8, 0xFF), // crystal blue
    .nand_gate = .init(0x93, 0x8A, 0xA9, 0xFF), // spring violet 1
    .or_gate = .init(0x76, 0x94, 0x6A, 0xFF), // autumn green
    .nor_gate = .init(0x95, 0x7F, 0xB8, 0xFF), // oni violet
    .xor_gate = .init(0x2D, 0x4F, 0x67, 0xFF), // wave blue 2
    .not_gate = .init(0xC3, 0x40, 0x43, 0xFF), // autumn red
};
