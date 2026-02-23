const std = @import("std");
const builtin = @import("builtin");
const zon = @import("build.zig.zon");
const rl = @import("raylib");

const Color = rl.Color;
const Vector2 = rl.Vector2;
const KeyboardKey = rl.KeyboardKey;

pub const project_name = "logic-sim";
pub const version_string = "v" ++ zon.version;
pub const web_build = builtin.target.os.tag == .emscripten;

pub const epsilon = 1e-9;
pub const epsilon_sqr = std.math.pow(f32, epsilon, 2);

pub const max_mod_name_size = 32;

pub const screen_width = 1280;
pub const screen_height = 720;
pub const screen_size: Vector2 = .init(screen_width, screen_height);
pub const font_size = 30;
pub const font_spacing = font_size * 0.1;

pub const escape_key: KeyboardKey = if (web_build) .escape else .caps_lock;
