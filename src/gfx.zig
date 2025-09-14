pub const Framebuffer = @import("gfx/Framebuffer.zig");
pub const color = @import("gfx/color.zig");

pub const Point = @Vector(2, usize);
pub const Rect = struct {
    corner: Point = .{ 0, 0 },
    dimensions: Point = .{ 0, 0 },

    pub fn isClear(self: Rect) bool {
        return @reduce(.And, (self.corner + self.dimensions) == Point{ 0, 0 });
    }

    pub fn add(self: *Rect, other: Rect) void {
        // same as isClear but we need the lower corner coordinates
        const self_lower_corner = self.corner + self.dimensions;
        if (@reduce(.And, self_lower_corner == Point{ 0, 0 })) {
            self.* = other;
            return;
        }

        const other_lower_corner = other.corner + other.dimensions;
        self.corner = @min(self.corner, other.corner);
        self.dimensions = @max(self_lower_corner, other_lower_corner) - self.corner;
    }
};
