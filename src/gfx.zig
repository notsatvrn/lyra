pub const Framebuffer = @import("gfx/Framebuffer.zig");
pub const color = @import("gfx/color.zig");

pub const Point = @Vector(2, usize);
pub const Aabb = struct { min: Point, max: Point };
