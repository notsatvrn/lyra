//! An implementation of the red-black tree, a self-balancing BST.
//!
//! Based on:
//! - https://github.com/msambol/dsa/blob/master/trees/red_black_tree.py
//! - https://github.com/xieqing/red-black-tree/blob/master/rb.c

const std = @import("std");
const Order = std.math.Order;

const memory = @import("../memory.zig");

// NODE

pub const Color = enum(u1) { red, black };

pub fn RBNode(comptime T: type) type {
    return struct {
        const Self = @This();

        value: T,
        color: Color = .red,
        parent: ?*Self = null,

        // left < self < right
        left: ?*Self = null,
        right: ?*Self = null,

        // SEARCHING

        pub fn min(x: *Self) *Self {
            var out = x;
            while (out.left != null)
                out = out.left.?;

            return x;
        }

        pub fn max(x: *Self) *Self {
            var out = x;
            while (out.right != null)
                out = out.right.?;

            return x;
        }
    };
}

// TREE

pub fn RBTree(comptime T: type, comptime cmp: fn (T, T) Order) type {
    return struct {
        const Self = @This();
        pub const Node = RBNode(T);
        const Pool = std.heap.MemoryPoolExtra(Node, .{ .alignment = @alignOf(Node) });

        pool: Pool = Pool.init(memory.allocator),
        root: ?*Node = null,

        // SEARCHING

        pub fn findNode(self: Self, value: T) ?*Node {
            var current = self.root;
            if (current == null) return null;
            var ord = cmp(value, current.?.value);

            while (true) {
                current = switch (ord) {
                    .lt => current.?.left,
                    .gt => current.?.right,
                    .eq => return current,
                };

                if (current == null) return null;
                ord = cmp(value, current.?.value);
            }
        }

        // ROTATION

        fn leftRotate(self: *Self, x: *Node) void {
            const y = x.right.?;
            x.right = y.left;

            if (y.left != null)
                y.left.?.parent = x;

            y.parent = x.parent;

            if (x.parent == null) {
                self.root = y;
            } else if (x == x.parent.?.left) {
                x.parent.?.left = y;
            } else {
                x.parent.?.right = y;
            }

            y.left = x;
            x.parent = y;
        }

        fn rightRotate(self: *Self, x: *Node) void {
            const y = x.left.?;
            x.left = y.right;

            if (y.right != null)
                y.right.?.parent = x;

            y.parent = x.parent;

            if (x.parent == null) {
                self.root = y;
            } else if (x == x.parent.?.right) {
                x.parent.?.right = y;
            } else {
                x.parent.?.left = y;
            }

            y.right = x;
            x.parent = y;
        }

        // INSERTION

        pub fn insert(self: *Self, value: T) !void {
            var node = try self.pool.create();
            node.* = .{ .value = value };

            if (self.root == null) {
                node.color = .black;
                self.root = node;
                return;
            }

            var parent = self.root.?;
            var tmp = self.root;

            while (tmp != null) {
                parent = tmp.?;
                tmp = switch (cmp(value, parent.value)) {
                    .lt => parent.left,
                    .gt => parent.right,
                    .eq => {
                        self.pool.destroy(node);
                        parent.value = value;
                        return;
                    },
                };
            }

            node.parent = parent;
            if (cmp(value, parent.value) == .lt) {
                parent.left = node;
            } else {
                parent.right = node;
            }

            self.insertRepair(node);

            return;
        }

        inline fn insertRepair(self: *Self, node: *Node) void {
            var current = node;

            while (current.parent != null and current.parent.?.color == .red) {
                const parent = current.parent.?;
                const grandparent = parent.parent.?;

                if (grandparent.left != null and parent == grandparent.left.?) {
                    var pibling = grandparent.right;

                    if (pibling != null and pibling.?.color == .red) {
                        parent.color = .black;
                        pibling.?.color = .black;
                        grandparent.color = .red;
                        current = grandparent;
                    } else {
                        if (current == parent.right.?) {
                            current = parent;
                            self.leftRotate(current);
                        }
                        parent.color = .black;
                        grandparent.color = .red;
                        self.rightRotate(grandparent);
                    }
                } else {
                    var pibling = grandparent.left;

                    if (pibling != null and pibling.?.color == .red) {
                        parent.color = .black;
                        pibling.?.color = .black;
                        grandparent.color = .red;
                        current = grandparent;
                    } else {
                        if (current == parent.left.?) {
                            current = parent;
                            self.rightRotate(current);
                        }
                        parent.color = .black;
                        grandparent.color = .red;
                        self.leftRotate(grandparent);
                    }
                }

                if (current == self.root) break;
            }

            self.root.?.color = .black;
        }

        // DELETION

        // transplant the new node into the place of the old one
        inline fn transplant(self: *Self, old: *Node, new: ?*Node) void {
            if (old.parent == null) {
                self.root = new;
            } else if (old == old.parent.?.left) {
                old.parent.?.left = new;
            } else {
                old.parent.?.right = new;
            }

            if (new) |n| n.parent = old.parent;
        }

        pub fn delete(self: *Self, value: T) bool {
            const node = self.findNode(value) orelse return false;
            defer self.pool.destroy(node);

            var old_color = node.color;
            var new: ?*Node = null;

            if (node.left == null) {
                // case 1: left child is null
                // this will also match if right child is null
                // in that case it just nullifies references to node
                new = node.right;
                self.transplant(node, new);
            } else if (node.right == null) {
                // case 2: right child is null
                new = node.left;
                self.transplant(node, new);
            } else {
                // case 3: both children are not null
                // use smaller child of right child
                var tmp = node.right.?.min();
                old_color = tmp.color;
                new = tmp.right;

                if (tmp.parent.? == node) {
                    if (new) |n| n.parent = tmp;
                } else {
                    self.transplant(tmp, new);
                    tmp.right = node.right;
                    tmp.right.?.parent = tmp;
                }

                // move tmp into node's place
                // also deal with left child
                self.transplant(node, tmp);
                tmp.left = node.left;
                tmp.left.?.parent = tmp;
                tmp.color = node.color;
            }

            if (old_color == .black)
                self.deleteRepair(new);

            return true;
        }

        inline fn deleteRepair(self: *Self, node: ?*Node) void {
            var current = node orelse return;

            while (current != self.root.? and current.color == .black) {
                var parent = current.parent.?;

                if (current == parent.left.?) {
                    var sibling = parent.right.?;

                    if (sibling.color == .red) {
                        sibling.color = .black;
                        parent.color = .red;
                        self.leftRotate(parent);
                        sibling = parent.right.?;
                    }

                    if (sibling.left.?.color == .black and
                        sibling.right.?.color == .black)
                    {
                        sibling.color = .red;
                        current = parent;
                    } else {
                        if (sibling.right.?.color == .black) {
                            sibling.left.?.color = .black;
                            sibling.color = .red;
                            self.rightRotate(sibling);
                            sibling = parent.right.?;
                        }

                        sibling.color = parent.color;
                        parent.color = .black;
                        sibling.right.?.color = .black;
                        self.leftRotate(parent);
                        current = self.root.?;
                    }
                } else {
                    var sibling = parent.left.?;

                    if (sibling.color == .red) {
                        sibling.color = .black;
                        parent.color = .red;
                        self.rightRotate(parent);
                        sibling = parent.left.?;
                    }

                    if (sibling.right.?.color == .black and
                        sibling.left.?.color == .black)
                    {
                        sibling.color = .red;
                        current = parent;
                    } else {
                        if (sibling.left.?.color == .black) {
                            sibling.right.?.color = .black;
                            sibling.color = .red;
                            self.leftRotate(sibling);
                            sibling = parent.left.?;
                        }

                        sibling.color = parent.color;
                        parent.color = .black;
                        sibling.left.?.color = .black;
                        self.rightRotate(parent);
                        current = self.root.?;
                    }
                }
            }

            current.color = .black;
        }
    };
}
