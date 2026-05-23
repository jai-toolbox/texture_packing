/*
 Binary Tree Rectangle Packing

 This is a classic binary tree bin-packing algorithm, commonly used for
 texture atlas generation. The goal is to pack many smaller rectangles
 (textures) into one large rectangle (the atlas).

 We start with one big empty rectangle (the atlas). Each time we place a
 block, we split the remaining free space into two smaller rectangles,
 forming a binary tree of free/used regions.

initialization

     make_split_packer(512, 512) creates a single root node representing
     the entire atlas, one big unused rectangle:

         +----------------------------------+
         |                                  |
         |           root (512x512)         |
         |            unused                |
         |                                  |
         +----------------------------------+

 placing blocks

     When fit() is called for a block (say 128x64), find_node_with_enough_space_rec
     searches the tree for an unused node big enough. When found, it:

         1. Marks the node as used.
         2. Splits the leftover space into two children:

         +--------+------------------------+
         | BLOCK  |     right child        |
         | 128x64 |   (384x64) unused      |
         | (used) |                        |
         +--------+------------------------+
         |                                 |
         |         down child              |
         |       (512x448) unused          |
         |                                 |
         +---------------------------------+

         - "right" = space to the right of the block
                      (same row, remaining width, block's height)
         - "down"  = space below the block
                      (full node width, remaining height)

 Subsequent Placements

     For the next block, the search recurses through the tree. At each used
     node, it checks the right child first, then the down child, looking for
     an unused node with enough space.

     For example, placing a 64x64 block next might go into the right child:

         +--------+------+-----------------+
         | BLOCK1 | BLK2 |  right' (320x64)|
         | 128x64 |64x64 |    unused       |
         +--------+------+-----------------+
         |  down' (unused, ...)            |
         +---------                        |
         |         down child               |
         |       (512x448) unused           |
         |                                  |
         +----------------------------------+

     Each placement further subdivides the tree.

 Failure
     If no unused node with enough space is found, find_node_with_enough_space_rec
     returns null, and the block's packed_placement is set to null meaning it
     didn't fit in the atlas.

 Summary
     Packed_Block_Node  -  A region in the atlas (either used or free space).
     Block_To_Pack      -  A texture to pack; stores its placement result.
     right child        -  Free space to the right of a placed block.
     down child         -  Free space below a placed block.
     Tree search        -  Depth-first: tries right then down at used nodes.

 NOTE: This algorithm works best when blocks are sorted by height (or area) descending before packing.
*/

Packed_Block_Node :: struct {
    top_left_x: int;
    top_left_y: int;

    w: int;
    h: int;

    used: bool = false;

    down:  *Packed_Block_Node = null;
    right: *Packed_Block_Node = null;
}

Block_To_Pack :: struct {
    w: int;
    h: int;
    packed_placement: *Packed_Block_Node = null;
}

Split_Packer :: struct {
    root: *Packed_Block_Node;
}

split_packer_profile_calls: u64;
split_packer_profile_max_depth: int;

reset_split_packer_profile :: () {
    split_packer_profile_calls = 0;
    split_packer_profile_max_depth = 0;
}

make_packed_block_node :: (x: int, y: int, w: int, h: int) -> *Packed_Block_Node {
    node := New(Packed_Block_Node);
    node.top_left_x = x;
    node.top_left_y = y;
    node.w = w;
    node.h = h;
    return node;
}

make_block_to_pack :: (w: int, h: int) -> Block_To_Pack {
    block: Block_To_Pack;
    block.w = w;
    block.h = h;
    return block;
}

make_split_packer :: (width: int, height: int) -> Split_Packer {
    packer: Split_Packer;
    packer.root = make_packed_block_node(0, 0, width, height);
    return packer;
}

find_node_with_enough_space_rec :: (node: *Packed_Block_Node, width: int, height: int, depth: int = 1) -> *Packed_Block_Node {
    if node == null then return null;

    Stack_Entry :: struct {
        node: *Packed_Block_Node;
        depth: int;
    }

    stack: [..] Stack_Entry;
    defer array_free(stack);
    array_add(*stack, .{node, depth});

    while stack.count > 0 {
        entry := pop(*stack);

        split_packer_profile_calls += 1;
        if entry.depth > split_packer_profile_max_depth split_packer_profile_max_depth = entry.depth;

        current := entry.node;
        if current == null continue;

        if current.used {
            // Push down first so right is processed first, matching the old recursion.
            if current.down  != null array_add(*stack, .{current.down,  entry.depth + 1});
            if current.right != null array_add(*stack, .{current.right, entry.depth + 1});
        } else if width <= current.w && height <= current.h {
            current.used = true;
            current.right = make_packed_block_node(
                current.top_left_x + width,
                current.top_left_y,
                current.w - width,
                height
            );
            current.down = make_packed_block_node(
                current.top_left_x,
                current.top_left_y + height,
                current.w,
                current.h - height
            );
            return current;
        }
    }

    return null;
}

fit :: (packer: *Split_Packer, blocks: [] *Block_To_Pack) {
    for blocks {
        fit(packer, it);
    }
}

fit :: (packer: *Split_Packer, block: *Block_To_Pack) {
    node := find_node_with_enough_space_rec(packer.root, block.w, block.h);
    if node != null {
        block.packed_placement = node;
    } else {
        block.packed_placement = null;
    }
}
