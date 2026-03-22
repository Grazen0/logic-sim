const rl = @import("raylib");
const rg = @import("raygui");

const Color = rl.Color;

const fuji_white: Color = .init(0xDC, 0xD7, 0xBA, 0xFF);
const old_white: Color = .init(0xC8, 0xC0, 0x93, 0xFF);
const sumi_ink_0: Color = .init(0x16, 0x16, 0x1D, 0xFF);
const sumi_ink_1: Color = .init(0x1F, 0x1F, 0x28, 0xFF);
const sumi_ink_0_dim: Color = .init(0x16, 0x16, 0x1D, 0xC0);
const sumi_ink_0_dim_dark: Color = .init(0x16, 0x16, 0x1D, 0xE0);
const sumi_ink_2: Color = .init(0x2A, 0x2A, 0x37, 0xFF);
const sumi_ink_3: Color = .init(0x36, 0x36, 0x46, 0xFF);
const sumi_ink_4: Color = .init(0x54, 0x54, 0x6D, 0xFF);

const wave_blue_2: Color = .init(0x2D, 0x4F, 0x67, 0xFF);
const autumn_green: Color = .init(0x76, 0x94, 0x6A, 0xFF);
const autumn_red: Color = .init(0xC3, 0x40, 0x43, 0xFF);
const dragon_blue: Color = .init(0x65, 0x85, 0x94, 0xFF);
const fuji_gray: Color = .init(0x72, 0x71, 0x69, 0xFF);
const spring_violet_1: Color = .init(0x93, 0x8A, 0xA9, 0xFF);
const oni_violet: Color = .init(0x95, 0x7F, 0xB8, 0xFF);
const crystal_blue: Color = .init(0x7E, 0x9C, 0xD8, 0xFF);
const katana_gray: Color = .init(0x71, 0x7C, 0x7C, 0xFF);

pub const background = sumi_ink_1;
pub const background_alt = sumi_ink_2;
pub const background_dark = sumi_ink_0;
pub const dim = sumi_ink_0_dim;
pub const tooltip_bg = sumi_ink_0_dim_dark;
pub const text = fuji_white;
pub const text_muted = sumi_ink_4;
pub const selection_border: Color = .init(0x00, 0x00, 0x00, 0x80);
pub const port = Color.black;
pub const logic_on = autumn_red;
pub const logic_off = sumi_ink_4;
pub const and_gate = crystal_blue;
pub const nand_gate = spring_violet_1;
pub const or_gate = autumn_green;
pub const nor_gate = oni_violet;
pub const xor_gate = wave_blue_2;
pub const not_gate = autumn_red;
pub const slice = katana_gray;
pub const split = katana_gray;
pub const join = katana_gray;
pub const clock = dragon_blue;
pub const display_seg_on = autumn_red;
pub const display_seg_off = sumi_ink_2;

pub fn loadStyle() void {
    rg.setStyle(.default, .{ .control = .border_color_normal }, sumi_ink_4.toInt());
    rg.setStyle(.default, .{ .control = .base_color_normal }, sumi_ink_1.toInt());
    rg.setStyle(.default, .{ .control = .text_color_normal }, fuji_white.toInt());
    rg.setStyle(.default, .{ .control = .border_color_focused }, sumi_ink_4.toInt());
    rg.setStyle(.default, .{ .control = .base_color_focused }, sumi_ink_2.toInt());
    rg.setStyle(.default, .{ .control = .text_color_focused }, fuji_white.toInt());
    rg.setStyle(.default, .{ .control = .border_color_pressed }, sumi_ink_4.toInt());
    rg.setStyle(.default, .{ .control = .base_color_pressed }, sumi_ink_3.toInt());
    rg.setStyle(.default, .{ .control = .text_color_pressed }, old_white.toInt());
    rg.setStyle(.default, .{ .control = .border_color_disabled }, sumi_ink_2.toInt());
    rg.setStyle(.default, .{ .control = .base_color_disabled }, sumi_ink_1.toInt());
    rg.setStyle(.default, .{ .control = .text_color_disabled }, fuji_gray.toInt());
    rg.setStyle(.default, .{ .control = .border_width }, 2);
    rg.setStyle(.default, .{ .default = .text_size }, 22);
    rg.setStyle(.default, .{ .default = .text_spacing }, 3);
    rg.setStyle(.default, .{ .default = .line_color }, sumi_ink_4.toInt());
    rg.setStyle(.default, .{ .default = .background_color }, sumi_ink_1.toInt());
    rg.setStyle(.default, .{ .default = .text_line_spacing }, 33);
}
