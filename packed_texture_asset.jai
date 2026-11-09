// Versioned little-endian disk format, independent of the in-memory struct
// layout. Counts are checked before allocation; old caches regenerate safely.
PACKED_TEXTURE_ASSET_MAGIC :: 0x32545850;
PACKED_TEXTURE_ASSET_VERSION :: 1;

Packed_Texture_Asset_Cursor :: struct {
    remaining: string;
    valid: bool = true;
}

packed_asset_take :: (cursor: *Packed_Texture_Asset_Cursor, count: s64) -> string {
    if !cursor.valid || count < 0 || count > cursor.remaining.count {
        cursor.valid = false;
        return "";
    }
    result := string.{count, cursor.remaining.data};
    cursor.remaining.data += count;
    cursor.remaining.count -= count;
    return result;
}

packed_asset_read_integer :: (cursor: *Packed_Texture_Asset_Cursor, count: int = 4) -> u64 {
    bytes := packed_asset_take(cursor, count);
    value: u64;
    for index: 0..bytes.count - 1 {
        byte := cast(u64) bytes.data[index];
        value |= byte << cast(u64) (index * 8);
    }
    return value;
}

packed_asset_write_integer :: (destination: **u8, value: u64, count: int = 4) {
    for index: 0..count - 1 {
        (destination.*)[index] = cast(u8) ((value >> cast(u64) (index * 8)) & 255);
    }
    destination.* += count;
}

save_packed_textures_asset :: (textures: *Packed_Textures, path: string) -> bool {
    if !packed_textures_valid(textures) return false;
    byte_count: s64 = 24;
    for placement: textures.texture_placements byte_count += 24 + placement.path.count;
    for mip: textures.pages.mips byte_count += 12 + mip.pixels.count;
    bytes := cast(*u8) alloc(byte_count);
    defer free(bytes);
    next := bytes;
    packed_asset_write_integer(*next, PACKED_TEXTURE_ASSET_MAGIC);
    packed_asset_write_integer(*next, PACKED_TEXTURE_ASSET_VERSION);
    packed_asset_write_integer(*next, ifx textures.compressed then cast(u64) 1 else cast(u64) 0);
    packed_asset_write_integer(*next, xx textures.texture_placements.count);
    packed_asset_write_integer(*next, xx textures.pages.page_count_per_mip_level);
    packed_asset_write_integer(*next, xx textures.pages.mips.count);
    for placement: textures.texture_placements {
        packed_asset_write_integer(*next, xx placement.top_left_x);
        packed_asset_write_integer(*next, xx placement.top_left_y);
        packed_asset_write_integer(*next, xx placement.w);
        packed_asset_write_integer(*next, xx placement.h);
        packed_asset_write_integer(*next, xx placement.page_index);
        packed_asset_write_integer(*next, xx placement.path.count);
        memcpy(next, placement.path.data, placement.path.count);
        next += placement.path.count;
    }
    for mip: textures.pages.mips {
        packed_asset_write_integer(*next, xx mip.page_side_length_px);
        packed_asset_write_integer(*next, xx mip.pixels.count, 8);
        memcpy(next, mip.pixels.data, mip.pixels.count);
        next += mip.pixels.count;
    }
    assert(next - bytes == byte_count);
    return write_entire_file(path, bytes, byte_count);
}

decode_packed_textures_asset :: (bytes: string) -> bool, Packed_Textures {
    result: Packed_Textures;
    cursor := Packed_Texture_Asset_Cursor.{remaining = bytes};
    succeeded := false;
    defer { if !succeeded deinit(*result); }
    if packed_asset_read_integer(*cursor) != PACKED_TEXTURE_ASSET_MAGIC return false, .{};
    if packed_asset_read_integer(*cursor) != PACKED_TEXTURE_ASSET_VERSION return false, .{};
    format := packed_asset_read_integer(*cursor);
    texture_count := packed_asset_read_integer(*cursor);
    page_count := packed_asset_read_integer(*cursor);
    mip_count := packed_asset_read_integer(*cursor);
    if !cursor.valid || format > 1 || texture_count == 0 || texture_count > MAX_NUM_PACKED_TEXTURES
        || page_count == 0 || page_count > 2048 || mip_count == 0 || mip_count > 15 return false, .{};
    result.compressed = format == 1;
    result.pages.page_count_per_mip_level = xx page_count;
    for index: 0..texture_count - 1 {
        placement: Texture_Placement;
        placement.top_left_x = xx packed_asset_read_integer(*cursor);
        placement.top_left_y = xx packed_asset_read_integer(*cursor);
        placement.w = xx packed_asset_read_integer(*cursor);
        placement.h = xx packed_asset_read_integer(*cursor);
        placement.page_index = xx packed_asset_read_integer(*cursor);
        path_count := packed_asset_read_integer(*cursor);
        if !cursor.valid || path_count == 0 || path_count > 65536 return false, .{};
        path := packed_asset_take(*cursor, xx path_count);
        if !cursor.valid return false, .{};
        placement.path = copy_string(path);
        array_add(*result.texture_placements, placement);
    }
    expected_side: s32;
    for index: 0..mip_count - 1 {
        side := packed_asset_read_integer(*cursor);
        byte_count := packed_asset_read_integer(*cursor, 8);
        if !cursor.valid || side == 0 || side > 16384 || (side & (side - 1)) != 0 return false, .{};
        if index > 0 && side != cast(u64) expected_side return false, .{};
        expected_side = max(cast(s32) 1, cast(s32) side / 2);
        expected_bytes := packed_texture_page_byte_count(xx side, result.compressed) * cast(s64) page_count;
        if byte_count != cast(u64) expected_bytes || byte_count > cast(u64) cursor.remaining.count return false, .{};
        pixels := packed_asset_take(*cursor, xx byte_count);
        mip := Packed_Texture_Pages_At_Mip_Level.{page_side_length_px = xx side};
        array_resize(*mip.pixels, xx byte_count);
        memcpy(mip.pixels.data, pixels.data, xx byte_count);
        array_add(*result.pages.mips, mip);
    }
    if !cursor.valid || cursor.remaining.count != 0 || !packed_textures_valid(*result) return false, .{};
    succeeded = true;
    return true, result;
}

load_packed_textures_asset :: (path: string) -> success: bool, result: Packed_Textures {
    if assets_initialized && assets.mode == .SIMPLE_PACKAGE {
        found, packaged_bytes := load_asset(path);
        if !found return false, .{};
        decoded, pack := decode_packed_textures_asset(packaged_bytes);
        return decoded, pack;
    }
    bytes, loaded := read_entire_file(path);
    if !loaded return false, .{};
    defer free(bytes);
    decoded, pack := decode_packed_textures_asset(bytes);
    return decoded, pack;
}
