const std = @import("std");
const math = std.math;

const direction = enum {
    left,
    center,
    right,

    fn invert(self: direction) direction {
        switch (self) {
            .left => return .right,
            .right => return .left,
            .center => return .center,
        }
    }
};

fn makeNodeData(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        const ChildCountType = u28;
        k: K,
        v: V,
        h: u8,
        l: ChildCountType,
        r: ChildCountType,

        fn childrenCount(self: *const Self) ChildCountType {
            return self.l + self.r;
        }

        fn setHeight(self: *Self, h: u8) bool {
            var old = self.h;
            self.h = h;
            return old != h;
        }
    };
}

fn makeNode(comptime K: type, comptime V: type, comptime L: type) type {
    return struct {
        const Self = @This();
        const NodeData = makeNodeData(K, V);

        data: NodeData,
        left: ?L,
        right: ?L,
        parent: ?L,

        fn init(k: K, v: V) Self {
            return Self{
                .data = NodeData{
                    .k = k,
                    .v = v,
                    .h = 0,
                    .l = 0,
                    .r = 0,
                },
                .left = null,
                .right = null,
                .parent = null,
            };
        }
    };
}

fn makePtrLocationType(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        const Node = makeNode(K, V, Self);
        const NodeData = Node.NodeData;

        ptr: *Node,

        fn init(ptr: *Node) Self {
            return Self{
                .ptr = ptr,
            };
        }

        fn eq(self: *const Self, other: Self) bool {
            return self.ptr == other.ptr;
        }

        fn data(self: *const Self) *NodeData {
            return &self.ptr.data;
        }

        fn child(self: *const Self, comptime dir: direction) ?Self {
            switch (dir) {
                .left => return self.ptr.*.left,
                .right => return self.ptr.*.right,
                else => unreachable,
            }
        }

        fn setChild(self: *Self, comptime dir: direction, loc: ?Self) void {
            switch (dir) {
                .left => self.ptr.*.left = loc,
                .right => self.ptr.*.right = loc,
                else => unreachable,
            }
        }

        fn parent(self: *const Self) ?Self {
            return self.ptr.*.parent;
        }

        fn setParent(self: *Self, p: ?Self) void {
            self.ptr.*.parent = p;
        }

        fn recalcHeight(self: *Self) bool {
            var h: u8 = 0;
            if (self.ptr.*.left) |l| {
                h = 1 + l.ptr.*.data.h;
            }
            if (self.ptr.*.right) |r| {
                h = @max(h, 1 + r.ptr.*.data.h);
            }
            return self.data().setHeight(h);
        }

        fn recalcCounts(self: *Self) void {
            var l: NodeData.ChildCountType = 0;
            var r: NodeData.ChildCountType = 0;
            if (self.ptr.*.left) |left| {
                l = 1 + left.ptr.*.data.childrenCount();
            }
            if (self.ptr.*.right) |right| {
                r = 1 + right.ptr.*.data.childrenCount();
            }
            self.data().l = l;
            self.data().r = r;
        }

        fn balance(self: *const Self) i8 {
            var b: i8 = 0;
            if (self.ptr.*.right) |right| {
                b += 1 + @intCast(i8, right.ptr.*.data.h);
            }
            if (self.ptr.*.left) |left| {
                b -= 1 + @intCast(i8, left.ptr.*.data.h);
            }
            return b;
        }
    };
}

fn locationCache(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        const Location = makePtrLocationType(K, V);

        a: std.mem.Allocator,

        fn init(a: std.mem.Allocator) Self {
            return Self{
                .a = a,
            };
        }

        fn create(self: *Self, k: K, v: V) !Location {
            var node = try self.a.create(Location.Node);
            node.* = Location.Node.init(k, v);
            return Location.init(node);
        }

        fn destroy(self: *Self, loc: Location) void {
            self.a.destroy(loc.ptr);
        }
    };
}

// Options defines some parameters of the tree.
pub const Options = struct {
    // countChildren, if set, enables children counts for every node of the tree.
    // the numbers of children in the left and right subtrees allows to locate
    // a node by its position with a guaranteed complexity O(logn)
    countChildren: bool = false,
};

// Tree is a generic avl tree.
// AVL tree (https://en.wikipedia.org/wiki/AVL_tree) is a self-balancing binary search tree.
// For each node of the tree the heights of the left and right sub-trees differ by at most one.
// Find and Delete operations have O(logn) complexity.
//  K - key type
//  V - value type
//  Cmp - a comparator.
pub fn Tree(comptime K: type, comptime V: type, comptime Cmp: fn (a: K, b: K) math.Order) type {
    return struct {
        const Self = @This();

        const Cache = locationCache(K, V);
        const Location = Cache.Location;
        const Comparer = Cmp;

        const LocateResult = struct {
            loc: ?Location,
            dir: direction,
        };

        pub const Entry = struct {
            k: K,
            v: *V,
        };

        fn goLeft(loc: Location) Location {
            var l = loc;
            while (true) {
                var left = l.child(.left) orelse break;
                l = left;
            }
            return l;
        }

        fn goRight(loc: Location) Location {
            var r = loc;
            while (true) {
                var right = r.child(.right) orelse break;
                r = right;
            }
            return r;
        }

        fn nextInOrderLocation(loc: Location) ?Location {
            var l = loc;
            if (l.child(.right)) |r| {
                return goLeft(r);
            }
            while (true) {
                var parent = l.parent() orelse return null;
                var dir = childDir(parent, l);
                if (dir == .left or dir == .center) {
                    return parent;
                }
                l = parent;
            }
        }

        fn prevInOrderLocation(loc: Location) ?Location {
            var l = loc;
            if (l.child(.left)) |left| {
                return goRight(left);
            }
            while (true) {
                var parent = l.parent() orelse return null;
                var dir = childDir(parent, l);
                if (dir == .right or dir == .center) {
                    return parent;
                }
                l = parent;
            }
        }

        fn goLeftRight(loc: Location) ?Location {
            var l = loc;
            while (true) {
                l = goLeft(l);
                var right = l.child(.right) orelse return l;
                while (true) {
                    if (right.child(.left)) |right_left| {
                        l = right_left;
                        break;
                    }
                    if (right.child(.right)) |right_right| {
                        right = right_right;
                    } else {
                        return right;
                    }
                }
            }
            return l;
        }

        fn nextPostOrderLocation(loc: Location) ?Location {
            var l = loc;
            var parent = l.parent() orelse return null;
            var dir = childDir(parent, l);
            switch (dir) {
                .left => {
                    var right = parent.child(.right) orelse return parent;
                    return goLeftRight(right);
                },
                .right => return parent,
                else => unreachable,
            }
        }

        fn advance(loc: Location, count: isize) Location {
            var res = loc;
            var c = count;
            while (c > 0) {
                res = nextInOrderLocation(res) orelse return res;
                c -= 1;
            }
            while (c < 0) {
                res = prevInOrderLocation(res) orelse return res;
                c += 1;
            }
            return res;
        }

        fn reparent(parent: ?Location, dir: direction, child: ?Location) void {
            if (parent) |p| {
                setChildAt(p, dir, child);
            }
            if (child) |c| {
                var ch = c;
                ch.setParent(parent);
            }
        }

        fn childAt(loc: Location, dir: direction) ?Location {
            switch (dir) {
                .left => return loc.child(.left),
                .right => return loc.child(.right),
                else => unreachable,
            }
        }

        fn setChildAt(parent: Location, dir: direction, child: ?Location) void {
            var p = parent;
            switch (dir) {
                .left => p.setChild(.left, child),
                .right => p.setChild(.right, child),
                else => unreachable,
            }
        }

        fn childDir(loc: Location, other: Location) direction {
            if (loc.child(.left)) |left| {
                if (left.eq(other)) {
                    return .left;
                }
            }
            if (loc.child(.right)) |right| {
                if (right.eq(other)) {
                    return .right;
                }
            }
            return .center;
        }

        pub const Iterator = struct {
            tree: *Self,
            loc: ?Location,

            fn init(tree: *Self, loc: ?Location) Iterator {
                return Iterator{
                    .tree = tree,
                    .loc = loc,
                };
            }

            pub fn next(self: *Iterator) ?Entry {
                var l = self.loc orelse return null;
                var e = Entry{
                    .k = l.data().k,
                    .v = &l.data().v,
                };
                self.loc = nextInOrderLocation(l);
                return e;
            }

            pub fn prev(self: *Iterator) ?Entry {
                var l = self.loc orelse return null;
                var e = Entry{
                    .k = l.data().k,
                    .v = &l.data().v,
                };
                self.loc = prevInOrderLocation(l);
                return e;
            }
        };

        lc: Cache,
        options: Options,
        length: usize,
        root: ?Location,
        min: ?Location,
        max: ?Location,

        // init itializes the tree.
        pub fn init(a: std.mem.Allocator, options: Options) Self {
            return Self{
                .lc = Cache.init(a),
                .options = options,
                .length = 0,
                .root = null,
                .min = null,
                .max = null,
            };
        }

        pub fn deinit(self: *Self) void {
            var min = self.min orelse return;
            var loc = goLeftRight(min);
            while (true) {
                var l = loc orelse break;
                var next = nextPostOrderLocation(l);
                self.lc.destroy(l);
                loc = next;
            }
        }

        // len returns the number of elements.
        pub fn len(self: *Self) usize {
            return self.length;
        }

        // Insert inserts a node into the tree.
        // Returns true, if a new node was added, and false otherwise.
        // If the key `k` was present in the tree, node's value is updated to `v`.
        // Time complexity: O(logn).
        pub fn insert(self: *Self, k: K, v: V) !bool {
            var res = self.locate(k);
            if (res.loc) |l| {
                if (res.dir == .center) {
                    l.data().v = v;
                    return false;
                }
            }
            var new_node = try self.lc.create(k, v);
            self.length += 1;
            switch (res.dir) {
                .left, .right => {
                    var l = res.loc orelse unreachable;
                    reparent(res.loc, res.dir, new_node);
                    if (res.dir == .left and res.loc.?.eq(self.min.?)) {
                        self.min = new_node;
                    } else if (res.dir == .right and res.loc.?.eq(self.max.?)) {
                        self.max = new_node;
                    }
                    if (l.recalcHeight()) {
                        if (self.options.countChildren) {
                            l.recalcCounts();
                        }
                        self.checkBalance(l.parent(), false);
                    } else {
                        updateCounts(res.loc.?);
                    }
                },
                .center => {
                    self.root = new_node;
                    self.min = new_node;
                    self.max = new_node;
                },
            }
            return true;
        }

        fn deleteLocation(self: *Self, loc: Location) void {
            self.deleteAndReplace(loc);
            self.lc.destroy(loc);
        }

        // delete deletes a node from the tree.
        // Returns the value associated with k, if the node was present in the tree.
        // Time complexity: O(logn).
        pub fn delete(self: *Self, k: K) ?V {
            var res = self.locate(k);
            if (res.dir != .center) {
                return null;
            }
            var l = res.loc orelse return null;
            var v = l.data().v;
            self.deleteLocation(l);
            return v;
        }

        fn deleteAndReplace(self: *Self, loc: Location) void {
            var replacement = findReplacement(loc);
            if (self.min) |min| {
                if (loc.eq(min)) {
                    self.min = nextInOrderLocation(loc);
                }
            }
            if (self.max) |max| {
                if (loc.eq(max)) {
                    self.max = prevInOrderLocation(loc);
                }
            }
            var parent = loc.parent();
            self.length -= 1;
            if (replacement) |rep| {
                var replacement_parent = rep.parent().?;
                var replacement_dir = childDir(replacement_parent, rep);
                var inverted = replacement_dir.invert();
                if (replacement_parent.eq(loc)) {
                    if (parent) |p| {
                        reparent(p, childDir(p, loc), rep);
                    } else {
                        self.setRoot(rep);
                    }
                    reparent(rep, inverted, childAt(loc, inverted));
                    self.checkBalance(rep, true);
                    return;
                }
                var replacement_child = childAt(rep, inverted);
                reparent(replacement_parent, replacement_dir, replacement_child);
                if (parent) |p| {
                    reparent(p, childDir(p, loc), rep);
                } else {
                    self.setRoot(rep);
                }
                reparent(rep, .left, loc.child(.left));
                reparent(rep, .right, loc.child(.right));
                self.checkBalance(replacement_parent, true);
            } else {
                if (parent) |p| {
                    reparent(p, childDir(p, loc), replacement);
                    self.checkBalance(p, false);
                } else {
                    self.setRoot(null);
                }
            }
        }

        fn findReplacement(loc: Location) ?Location {
            var left = loc.child(.left);
            var right = loc.child(.right);
            if (left) |l| {
                if (right) |r| {
                    if (l.data().h <= r.data().h) {
                        return goRight(l);
                    }
                    return goLeft(r);
                }
                return goRight(l);
            } else if (right) |r| {
                return goLeft(r);
            }
            return null;
        }

        // getMin returns the minimum element of the tree.
        // Time complexity: O(1).
        pub fn getMin(self: *Self) ?Entry {
            if (self.min) |min| {
                return Entry{
                    .k = min.data().k,
                    .v = &min.data().v,
                };
            }
            return null;
        }

        // getMax returns the maximum element of the tree.
        // Time complexity: O(1).
        pub fn getMax(self: *Self) ?Entry {
            if (self.max) |max| {
                return Entry{
                    .k = max.data().k,
                    .v = &max.data().v,
                };
            }
            return null;
        }

        // ascendFromStart returns an iterator pointing to the first element.
        pub fn ascendFromStart(self: *Self) Iterator {
            return Iterator{
                .tree = self,
                .loc = self.min,
            };
        }

        // descendFromEnd returns an iterator pointing to the last element.
        pub fn descendFromEnd(self: *Self) Iterator {
            return Iterator{
                .tree = self,
                .loc = self.max,
            };
        }

        // get returns a value for key k.
        // Time complexity: O(logn).
        pub fn get(self: *Self, k: K) ?V {
            var res = self.locate(k);
            if (res.loc == null or res.dir != .center) {
                return null;
            }
            return res.loc.?.data().v;
        }

        // at returns a an entry at the ith position of the sorted array.
        // Panics if position >= tree.Len().
        // Time complexity:
        //	O(logn) - if children node counts are enabled.
        //	O(n) - otherwise.
        pub fn at(self: *Self, pos: usize) Entry {
            var loc = self.locateAt(pos);
            return Entry{
                .k = loc.data().k,
                .v = &loc.data().v,
            };
        }

        // deleteAt deletes a node at the given position.
        // Panics if position >= tree.Len().
        // Time complexity:
        //	O(logn) - if children node counts are enabled.
        //	O(n) - otherwise.
        pub fn deleteAt(self: *Self, pos: usize) void {
            self.deleteLocation(self.locateAt(pos));
        }

        fn setRoot(self: *Self, loc: ?Location) void {
            self.root = loc;
            if (self.root) |*root| {
                root.setParent(null);
            }
        }

        fn updateCounts(loc: Location) void {
            var mutLoc: ?Location = loc;
            while (true) {
                var l = mutLoc orelse break;
                l.recalcCounts();
                mutLoc = l.parent();
            }
        }

        fn checkBalance(self: *Self, loc: ?Location, all_way_up: bool) void {
            var mutLoc = loc;
            while (true) {
                var l = mutLoc orelse break;
                var heightChanged = l.recalcHeight();
                var parent = l.parent();
                switch (l.balance()) {
                    -2 => {
                        switch (l.child(.left).?.balance()) {
                            -1, 0 => self.rr(l),
                            1 => self.lr(l),
                            else => unreachable,
                        }
                    },
                    2 => {
                        switch (l.child(.right).?.balance()) {
                            -1 => self.rl(l),
                            0, 1 => self.ll(l),
                            else => unreachable,
                        }
                    },
                    else => {
                        if (!heightChanged and !all_way_up) {
                            updateCounts(l);
                            return;
                        }
                        if (self.options.countChildren) {
                            l.recalcCounts();
                        }
                    },
                }
                mutLoc = parent;
            }
        }

        fn rr(self: *Self, loc: Location) void {
            var l = loc;
            var left = l.child(.left) orelse unreachable;
            var left_right = left.child(.right);
            var parent = l.parent();
            if (parent) |p| {
                reparent(parent, childDir(p, l), left);
            } else {
                self.setRoot(left);
            }

            reparent(l, .left, left_right);
            reparent(left, .right, l);

            _ = l.recalcHeight();
            _ = left.recalcHeight();

            if (self.options.countChildren) {
                l.recalcCounts();
                left.recalcCounts();
            }
        }

        fn lr(self: *Self, loc: Location) void {
            var l = loc;
            var left = l.child(.left) orelse unreachable;
            var left_right = left.child(.right) orelse unreachable;
            var parent = l.parent();
            if (parent) |p| {
                reparent(parent, childDir(p, l), left_right);
            } else {
                self.setRoot(left_right);
            }
            var left_right_right = left_right.child(.right);
            var left_right_left = left_right.child(.left);

            reparent(left_right, .right, l);
            reparent(left_right, .left, left);

            reparent(l, .left, left_right_right);
            reparent(left, .right, left_right_left);

            _ = l.recalcHeight();
            _ = left.recalcHeight();
            _ = left_right.recalcHeight();

            if (self.options.countChildren) {
                l.recalcCounts();
                left.recalcCounts();
                left_right.recalcCounts();
            }
        }

        fn rl(self: *Self, loc: Location) void {
            var l = loc;
            var right = l.child(.right) orelse unreachable;
            var right_left = right.child(.left) orelse unreachable;
            var parent = l.parent();
            if (parent) |p| {
                reparent(parent, childDir(p, l), right_left);
            } else {
                self.setRoot(right_left);
            }

            var right_left_left = right_left.child(.left);
            var right_left_right = right_left.child(.right);

            reparent(right_left, .left, l);
            reparent(right_left, .right, right);

            reparent(l, .right, right_left_left);
            reparent(right, .left, right_left_right);

            _ = l.recalcHeight();
            _ = right.recalcHeight();
            _ = right_left.recalcHeight();

            if (self.options.countChildren) {
                l.recalcCounts();
                right.recalcCounts();
                right_left.recalcCounts();
            }
        }

        fn ll(self: *Self, loc: Location) void {
            var l = loc;
            var right = l.child(.right) orelse unreachable;
            var right_left = right.child(.left);
            var parent = l.parent();
            if (parent) |p| {
                reparent(parent, childDir(p, l), right);
            } else {
                self.setRoot(right);
            }

            reparent(l, .right, right_left);
            reparent(right, .left, l);

            _ = l.recalcHeight();
            _ = right.recalcHeight();

            if (self.options.countChildren) {
                l.recalcCounts();
                right.recalcCounts();
            }
        }

        fn locate(self: *Self, k: K) LocateResult {
            var result = LocateResult{
                .loc = self.root,
                .dir = .center,
            };
            while (true) {
                var l = result.loc orelse break;
                var next: ?Location = null;
                switch (Comparer(k, l.data().k)) {
                    .lt => {
                        next = l.child(.left);
                        result.dir = .left;
                    },
                    .eq => {
                        result.dir = .center;
                        return result;
                    },
                    .gt => {
                        next = l.child(.right);
                        result.dir = .right;
                    },
                }
                if (next == null) {
                    break;
                }
                result.loc = next;
            }
            return result;
        }

        fn shouldLocateAtLineary(self: *Self, pos: usize) bool {
            var p = @min(pos, self.length - pos - 1);
            return p <= 8;
        }

        fn locateAt(self: *Self, pos: usize) Location {
            if (pos >= self.len()) {
                @panic("index out of range");
            }
            if (!self.options.countChildren or self.shouldLocateAtLineary(pos)) {
                if (pos < self.length / 2) {
                    return advance(self.min.?, @intCast(isize, pos));
                }
                return advance(self.max.?, -@intCast(isize, self.length - pos - 1));
            }
            var loc = self.root.?;
            var p = pos;
            while (true) {
                var left_count = @intCast(usize, loc.data().l);
                if (p == left_count) {
                    return loc;
                }
                if (p < left_count) {
                    loc = loc.child(.left).?;
                } else {
                    p -= (left_count + 1);
                    loc = loc.child(.right).?;
                }
            }
        }
    };
}

fn i64Cmp(a: i64, b: i64) math.Order {
    return math.order(a, b);
}

test "empty tree" {
    var a = std.testing.allocator;
    const TreeType = Tree(i64, i64, i64Cmp);
    var t = TreeType.init(a, .{});
    defer t.deinit();

    var it = t.ascendFromStart();
    var e = it.next();
    try std.testing.expect(e == null);

    try std.testing.expect(t.delete(0) == null);
}

test "tree insert" {
    var a = std.testing.allocator;
    const TreeType = Tree(i64, i64, i64Cmp);
    var t = TreeType.init(a, .{});
    defer t.deinit();
    var i: i64 = 0;
    while (i < 128) {
        var inserted = try t.insert(i, i);
        try std.testing.expect(inserted);

        var min = t.getMin();
        try std.testing.expect(min != null);
        var exp: i64 = 0;
        try std.testing.expectEqual(exp, min.?.k);
        try std.testing.expectEqual(exp, min.?.v.*);

        var max = t.getMax();
        try std.testing.expect(max != null);
        try std.testing.expectEqual(i, max.?.k);
        try std.testing.expectEqual(i, max.?.v.*);

        try checkHeightAndBalance(
            i64,
            i64,
            TreeType.Comparer,
            t.root,
        );

        i += 1;
    }

    i = 0;
    while (i < 128) {
        var v = t.get(i);
        try std.testing.expect(v != null);
        try std.testing.expectEqual(i, v.?);
        i += 1;
    }

    i = 127;
    while (i >= 0) {
        var inserted = try t.insert(i, i * 2);
        try std.testing.expect(!inserted);
        try checkHeightAndBalance(
            i64,
            i64,
            TreeType.Comparer,
            t.root,
        );
        i -= 1;
    }

    i = 0;
    while (i < 128) {
        var v = t.get(i);
        try std.testing.expect(v != null);
        try std.testing.expectEqual(i * 2, v.?);
        i += 1;
    }
}

test "tree delete" {
    var a = std.testing.allocator;
    const TreeType = Tree(i64, i64, i64Cmp);
    var t = TreeType.init(a, .{ .countChildren = true });
    defer t.deinit();
    var exp_len: usize = 0;
    try std.testing.expectEqual(exp_len, t.len());
    try std.testing.expect(try t.insert(0, 0));
    var exp: i64 = 0;
    try std.testing.expectEqual(exp, t.delete(0).?);
    try checkHeightAndBalance(i64, i64, TreeType.Comparer, t.root);

    try std.testing.expect(try t.insert(0, 0));
    try std.testing.expect(try t.insert(-1, -1));
    exp_len = 2;
    try std.testing.expectEqual(exp_len, t.len());
    try checkHeightAndBalance(i64, i64, TreeType.Comparer, t.root);
    exp = 0;
    try std.testing.expectEqual(exp, t.delete(0).?);
    exp = -1;
    try std.testing.expectEqual(exp, t.delete(-1).?);
    exp_len = 0;
    try std.testing.expectEqual(exp_len, t.len());

    try std.testing.expect(try t.insert(0, 0));
    try std.testing.expect(try t.insert(1, 1));
    exp_len = 2;
    try std.testing.expectEqual(exp_len, t.len());
    try checkHeightAndBalance(i64, i64, TreeType.Comparer, t.root);
    exp = 1;
    try std.testing.expectEqual(exp, t.delete(1).?);
    exp_len = 1;
    try std.testing.expectEqual(exp_len, t.len());
    try std.testing.expectEqual(@as(?i64, null), t.delete(-1));
    try checkHeightAndBalance(i64, i64, TreeType.Comparer, t.root);
    exp = 0;
    try std.testing.expectEqual(exp, t.delete(0).?);
    exp_len = 0;
    try std.testing.expectEqual(exp_len, t.len());

    try std.testing.expect(try t.insert(0, 0));
    try std.testing.expect(try t.insert(1, 1));
    exp = 0;
    try std.testing.expectEqual(exp, t.delete(0).?);
    exp_len = 1;
    try std.testing.expectEqual(exp_len, t.len());
    try checkHeightAndBalance(i64, i64, TreeType.Comparer, t.root);
    exp = 1;
    try std.testing.expectEqual(exp, t.delete(1).?);
    try checkHeightAndBalance(i64, i64, TreeType.Comparer, t.root);
    exp_len = 0;
    try std.testing.expectEqual(exp_len, t.len());

    var i: i64 = 128;
    while (i >= 0) {
        try std.testing.expect(try t.insert(i, i));
        i -= 1;
    }
    i = 128;
    while (i >= 0) {
        try std.testing.expectEqual(i, t.delete(i).?);
        try checkHeightAndBalance(i64, i64, TreeType.Comparer, t.root);
        i -= 1;
    }
}

test "delete min" {
    var a = std.testing.allocator;
    const TreeType = Tree(i64, i64, i64Cmp);
    var t = TreeType.init(a, .{ .countChildren = true });
    defer t.deinit();

    var i: i64 = 0;
    while (i <= 128) {
        try std.testing.expect(try t.insert(i, i));
        i += 1;
    }
    i = 0;
    while (i <= 128) {
        var e = t.getMin();
        try std.testing.expectEqual(i, e.?.k);
        try std.testing.expectEqual(i, e.?.v.*);
        try std.testing.expectEqual(i, t.delete(i).?);
        i += 1;
    }
    var exp_len: usize = 0;
    try std.testing.expectEqual(exp_len, t.len());
}

test "delete max" {
    var a = std.testing.allocator;
    const TreeType = Tree(i64, i64, i64Cmp);
    var t = TreeType.init(a, .{ .countChildren = true });
    defer t.deinit();

    var i: i64 = 0;
    while (i <= 128) {
        try std.testing.expect(try t.insert(i, i));
        i += 1;
    }
    i = 0;
    while (i <= 128) {
        var e = t.getMax();
        try std.testing.expectEqual(128 - i, e.?.k);
        try std.testing.expectEqual(128 - i, e.?.v.*);
        try std.testing.expectEqual(128 - i, t.delete(128 - i).?);
        i += 1;
    }
    var exp_len: usize = 0;
    try std.testing.expectEqual(exp_len, t.len());
}

test "tree at_countChildren" {
    var a = std.testing.allocator;
    const TreeType = Tree(i64, i64, i64Cmp);
    var t = TreeType.init(a, .{ .countChildren = true });
    defer t.deinit();

    var i: i64 = 0;
    while (i <= 128) {
        try std.testing.expect(try t.insert(i, i));
        i += 1;
    }

    i = 0;
    while (i <= 128) {
        var e = t.at(@intCast(usize, i));
        try std.testing.expectEqual(i, e.k);
        try std.testing.expectEqual(i, e.v.*);
        i += 1;
    }
}

test "tree at_nocountChildren" {
    var a = std.testing.allocator;
    const TreeType = Tree(i64, i64, i64Cmp);
    var t = TreeType.init(a, .{ .countChildren = false });
    defer t.deinit();

    var i: i64 = 0;
    while (i <= 128) {
        try std.testing.expect(try t.insert(i, i));
        i += 1;
    }

    i = 0;
    while (i <= 128) {
        var e = t.at(@intCast(usize, i));
        try std.testing.expectEqual(i, e.k);
        try std.testing.expectEqual(i, e.v.*);
        i += 1;
    }
}

test "tree deleteAt" {
    var a = std.testing.allocator;
    const TreeType = Tree(i64, i64, i64Cmp);
    var t = TreeType.init(a, .{ .countChildren = true });
    defer t.deinit();

    var i: i64 = 0;
    while (i < 128) {
        try std.testing.expect(try t.insert(i, i));
        i += 1;
    }

    var exp_len: usize = 128;
    i = 64;
    while (i < 128) {
        try std.testing.expectEqual(exp_len, t.len());
        t.deleteAt(64);
        i += 1;
        exp_len -= 1;
    }

    i = 0;
    while (i < 64) {
        try std.testing.expectEqual(exp_len, t.len());
        t.deleteAt(0);
        i += 1;
        exp_len -= 1;
    }
    try std.testing.expectEqual(exp_len, t.len());
}

test "tree iterator" {
    var a = std.testing.allocator;
    const TreeType = Tree(i64, i64, i64Cmp);
    var t = TreeType.init(a, .{ .countChildren = true });
    defer t.deinit();

    var i: i64 = 0;
    while (i < 128) {
        try std.testing.expect(try t.insert(i, i));
        i += 1;
    }
    var it = t.ascendFromStart();
    i = 0;
    while (i < 128) {
        var e = it.next();
        try std.testing.expectEqual(i, e.?.k);
        try std.testing.expectEqual(i, e.?.v.*);
        i += 1;
    }
    try std.testing.expectEqual(@as(?TreeType.Entry, null), it.next());

    it = t.descendFromEnd();
    i = 127;
    while (i >= 0) {
        var e = it.prev();
        try std.testing.expectEqual(i, e.?.k);
        try std.testing.expectEqual(i, e.?.v.*);
        i -= 1;
    }
    try std.testing.expectEqual(@as(?TreeType.Entry, null), it.next());
}

test "tree random" {
    var a = std.testing.allocator;
    const TreeType = Tree(i64, i64, i64Cmp);
    var t = TreeType.init(a, .{ .countChildren = true });
    defer t.deinit();
    var arr = try a.alloc(i64, 2048);
    for (arr, 0..) |_, idx| {
        arr[idx] = @intCast(i64, idx);
    }
    defer a.free(arr);
    var i: i64 = 0;
    while (i < 10) {
        var exp_len: usize = 0;
        var r = std.rand.DefaultPrng.init(0);
        r.random().shuffle(i64, arr);
        for (arr) |val| {
            try std.testing.expect(try t.insert(val, val));
            try checkHeightAndBalance(i64, i64, TreeType.Comparer, t.root);
        }
        r.random().shuffle(i64, arr);
        for (arr) |val| {
            try std.testing.expectEqual(val, t.delete(val).?);
            try checkHeightAndBalance(i64, i64, TreeType.Comparer, t.root);
        }
        try std.testing.expectEqual(exp_len, t.len());
        i += 1;
    }
}

fn checkHeightAndBalance(comptime K: type, comptime V: type, comptime Cmp: fn (a: K, b: K) math.Order, loc: ?Tree(K, V, Cmp).Location) !void {
    _ = try recalcHeightAndBalance(K, V, Cmp, loc);
}

const recalcResult = struct {
    height: u8,
    l_count: u32,
    r_count: u32,

    fn init() recalcResult {
        return recalcResult{
            .height = 0,
            .l_count = 0,
            .r_count = 0,
        };
    }
};

fn recalcHeightAndBalance(comptime K: type, comptime V: type, comptime Cmp: fn (a: K, b: K) math.Order, loc: ?Tree(K, V, Cmp).Location) !recalcResult {
    var result = recalcResult.init();
    var l = loc orelse return result;
    if (l.child(.left) != null) {
        var lRes = try recalcHeightAndBalance(K, V, Cmp, l.child(.left));
        result.height = 1 + lRes.height;
        result.l_count = lRes.l_count + lRes.r_count + 1;
    }
    if (l.child(.right) != null) {
        var rRes = try recalcHeightAndBalance(K, V, Cmp, l.child(.right));
        result.height = @max(result.height, 1 + rRes.height);
        result.r_count = rRes.r_count + rRes.l_count + 1;
    }
    try std.testing.expectEqual(result.height, l.data().h);
    if (l.balance() < -1 or l.balance() > 1) {
        return error{
            InvalidBalance,
        }.InvalidBalance;
    }
    return result;
}