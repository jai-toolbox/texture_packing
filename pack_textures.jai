#import "stb_image_write";
#import "stb_image";
#import "stb_image_resize";

#import "File_Utilities";
#import "String";

RGBA8_CHANNEL_COUNT :: 4;
RGBA8_BYTES_PER_PIXEL :: 4;

get_texture_paths :: (directory: string) -> [..] string {
    image_file_paths: [..] string;

    visitor :: (info: *File_Visit_Info, paths: *[..] string) {
        if info.is_directory {
            if info.short_name == "packed_textures" {
                info.descend_into_directory = false;
            }
            return;
        }

        ext := path_extension(info.full_name);
        if ext == "png" || ext == "jpg" || ext == "tga" || ext == "jpeg" {
            normalized_path := copy_string(info.full_name);
            normalize_slashes(normalized_path);
            array_add(paths, normalized_path);
        }
    };

    visit_files(directory, recursive = true, *image_file_paths, visitor, visit_directories = true);

    return image_file_paths;
}

get_texture_paths :: (directories: [] string) -> [..] string {
    result: [..] string;

    for directories {
        paths := get_texture_paths(it);
        for paths array_add(*result, it);
    }

    return result;
}

Texture_Block_To_Pack :: struct { 
    using #as base : Block_To_Pack;

    path: string;
    source_width: int;
    source_height: int;
    
    /*
    todo in the future we might need recursion for when the texture you just packed is an atlas right?
    potentially not though. maybe all we need is a conversion function or something like that.
    */
}

Texture_Page_Packing :: struct {
    packer: Split_Packer;
    blocks: [..] *Texture_Block_To_Pack;
    source_texture_width: int;
    source_texture_height: int;
}

// everything could be unsigned maybe do it later when you're bored and read this comment
// its later and I read this comment and I dont care lol
Texture_Placement :: struct {
    top_left_x: int;
    top_left_y: int;
    w: int;
    h: int;
    path: string;
    page_index: int;
}

#import "Sort";
#import "File";
#import "Math";
#import "tbx/serialize";

MAX_NUM_PACKED_TEXTURES :: 1024;

Packed_Texture_Layout :: struct {
    side_length_px : int; // could be unsigned but probably doesn't matter
    textures: [..] Texture_Placement;
}

// the saved CPU asset contains the finished page pixels and their source placements.
Packed_Textures :: struct {
    // true means every page at every mip is stored as BC3 (DXT5); false means RGBA8.
    compressed: bool;
    texture_placements: [..] Texture_Placement;
    pages: Packed_Texture_Pages;
}

Packed_Texture_Pages_At_Mip_Level :: struct {
    page_side_length_px: s32;
    // all pages are contiguous: RGBA8 texel rows or BC3 block rows, as selected by compressed.
    pixels: [..] u8;
}

Packed_Texture_Pages :: struct {
    // mips[0] is the original resolution; each following entry halves the page dimensions.
    mips: [..] Packed_Texture_Pages_At_Mip_Level;
    page_count_per_mip_level: s32;
}

packed_texture_page_byte_count :: (side_length_px: s32, compressed: bool) -> s64 {
    if compressed {
        blocks_per_axis := (cast(s64) side_length_px + BC3_BLOCK_SIDE_LENGTH_PX - 1)
            / BC3_BLOCK_SIDE_LENGTH_PX;
        return blocks_per_axis * blocks_per_axis * BC3_BYTES_PER_BLOCK;
    }
    return cast(s64) side_length_px * side_length_px * RGBA8_BYTES_PER_PIXEL;
}

// returns a byte offset within the requested mip's pixel buffer.
flatten_index :: (ptp: Packed_Texture_Pages, mip: s32, page: s32, compressed: bool = false) -> s64 {
    assert(mip >= 0 && mip < ptp.mips.count);
    assert(page >= 0 && page < ptp.page_count_per_mip_level);
    level := *ptp.mips[mip];
    assert(level.page_side_length_px > 0);
    page_byte_count := packed_texture_page_byte_count(level.page_side_length_px, compressed);
    return page * page_byte_count;
}

copy_texture_pixels_into_page :: (
    pages: *Packed_Texture_Pages,
    placement: Texture_Placement,
    mipmap_level: s32,
    pixels: *u8,
    width: s32,
    height: s32,
) {
    page_byte_offset := flatten_index(pages.*, mipmap_level, cast(s32) placement.page_index);
    level := *pages.mips[mipmap_level];
    destination_x := placement.top_left_x >> mipmap_level;
    destination_y := placement.top_left_y >> mipmap_level;
    assert(pixels != null && width > 0 && height > 0);
    assert(destination_x >= 0 && destination_y >= 0);
    assert(width <= level.page_side_length_px && height <= level.page_side_length_px);
    assert(destination_x <= level.page_side_length_px - width);
    assert(destination_y <= level.page_side_length_px - height);

    source_row_byte_count := cast(s64) width * RGBA8_BYTES_PER_PIXEL;
    destination_row_byte_count := cast(s64) level.page_side_length_px * RGBA8_BYTES_PER_PIXEL;
    destination := level.pixels.data
        + page_byte_offset
        + destination_y * destination_row_byte_count
        + destination_x * RGBA8_BYTES_PER_PIXEL;
    for row: 0..height - 1 {
        memcpy(
            destination + row * destination_row_byte_count,
            pixels + row * source_row_byte_count,
            source_row_byte_count,
        );
    }
}

deinit :: (ptp: *Packed_Texture_Pages) {
    for *level: ptp.mips array_free(level.pixels);
    array_free(ptp.mips);
    ptp.* = .{};
}


deinit :: (textures: *Packed_Textures) {
    deinit(*textures.pages);
    for *texture: textures.texture_placements {
        if texture.path.count > 0 free(texture.path);
    }
    array_free(textures.texture_placements);
    textures.* = .{};
}

next_power_of_two_for_texture_packing :: (value: int) -> int {
    result := 1;
    while result < value result *= 2;
    return result;
}

packed_textures_match_paths :: (
    textures: *Packed_Textures,
    texture_paths: [] string,
) -> bool {
    if textures.texture_placements.count != texture_paths.count return false;
    for path: texture_paths {
        found := false;
        for texture: textures.texture_placements {
            if texture.path == path {
                found = true;
                break;
            }
        }
        if !found return false;
    }
    return true;
}

packed_textures_valid :: (textures: *Packed_Textures) -> bool {
    if textures.texture_placements.count <= 0
        || textures.texture_placements.count > MAX_NUM_PACKED_TEXTURES return false;
    pages := *textures.pages;
    if pages.page_count_per_mip_level <= 0 || pages.mips.count <= 0 return false;
    side_length_px := pages.mips[0].page_side_length_px;
    if side_length_px <= 0 return false;
    for level: pages.mips {
        if level.page_side_length_px != side_length_px return false;
        expected_byte_count := packed_texture_page_byte_count(side_length_px, textures.compressed)
            * pages.page_count_per_mip_level;
        if level.pixels.count != expected_byte_count return false;
        side_length_px = max(cast(s32) 1, side_length_px / 2);
    }
    base_side_length_px := pages.mips[0].page_side_length_px;
    for texture: textures.texture_placements {
        if texture.page_index < 0 || texture.page_index >= pages.page_count_per_mip_level return false;
        if texture.w <= 0 || texture.h <= 0
            || texture.w > base_side_length_px || texture.h > base_side_length_px return false;
        if texture.top_left_x < 0 || texture.top_left_y < 0
            || texture.top_left_x > base_side_length_px - texture.w
            || texture.top_left_y > base_side_length_px - texture.h return false;
    }
    return true;
}

// cache files follow the current struct layout; regenerate them after layout changes.
save_packed_textures_asset :: (
    textures: *Packed_Textures,
    path: string,
) -> bool {
    if !packed_textures_valid(textures) return false;
    byte_count := size_when_serialized(textures.*);
    bytes := alloc(byte_count);
    defer free(bytes);
    bytes_written := serialize(bytes, textures.*);
    if bytes_written != byte_count return false;
    return write_entire_file(path, bytes, bytes_written);
}

load_packed_textures_asset :: (path: string) -> success: bool, result: Packed_Textures {
    file_contents, read_success := read_entire_file(path);
    if !read_success return false, .{};
    defer free(file_contents);

    result, bytes_read := deserialize(
        cast(*void) file_contents.data,
        Packed_Textures);
    if bytes_read != file_contents.count || !packed_textures_valid(*result) {
        deinit(*result);
        return false, .{};
    }
    return true, result;
}

recommended_texture_pack_side_length :: (
    texture_paths: [] string,
    minimum_side_length: int = 1024,
    maximum_side_length: int = 4096,
) -> int {
    largest_dimension := 0;
    for path: texture_paths {
        w, h, channels: s32;
        if stbi_info(temp_c_string(path), *w, *h, *channels) {
            largest_dimension = max(largest_dimension, cast(int) max(w, h));
        }
    }

    side_length := 1;
    while side_length < largest_dimension side_length *= 2;
    return min(max(side_length, minimum_side_length), maximum_side_length);
}

append_packed_texture_using_allocator :: (
    metadata: *Packed_Texture_Layout,
    packed_texture: Texture_Placement,
    allocator: Allocator,
) {
    push_allocator(allocator);
    persistent_texture := packed_texture;
    persistent_texture.path = copy_string(packed_texture.path);
    array_add(*metadata.textures, persistent_texture);
}

/*
computes atlas placement without creating, encoding, or writing atlas
images. The returned metadata owns its path strings and can be kept by a
renderer after the temporary packing nodes are released.
*/
build_packed_texture_metadata :: (side_length_px: int, texture_paths: [] string) -> Packed_Texture_Layout {
    metadata: Packed_Texture_Layout;
    result_allocator := context.allocator;
    push_allocator(temp);
    auto_release_temp();

    texture_blocks: [..] *Texture_Block_To_Pack;
    for path: texture_paths {
        width, height, channels: s32;
        if !stbi_info(temp_c_string(path), *width, *height, *channels) {
            log_error("Failed to read image info: %", path);
            continue;
        }

        // think about if we can just use a temp allocator for this and then when done we're done lol
        block := New(Texture_Block_To_Pack);
        block.source_width = cast(int) width;
        block.source_height = cast(int) height;
        // power-of-two cells keep every placement aligned as mip levels shrink.
        block.w = next_power_of_two_for_texture_packing(block.source_width);
        block.h = next_power_of_two_for_texture_packing(block.source_height);
        block.path = path;
        array_add(*texture_blocks, block);
    }

    quick_sort(texture_blocks, (a, b) => b.source_height - a.source_height);

    pages: [..] Texture_Page_Packing;
    for block: texture_blocks {
        placed := false;
        for *page: pages {
            // one page becomes one OpenGL texture-array layer. keeping exact
            // source dimensions together means every packed region on that
            // page reaches 1x1 at the same mip level.
            if page.source_texture_width != block.source_width
                || page.source_texture_height != block.source_height continue;
            fit(*page.packer, block);
            if block.packed_placement != null {
                array_add(*page.blocks, block);
                placed = true;
                break;
            }
        }

        if !placed {
            new_page: Texture_Page_Packing;
            new_page.source_texture_width = block.source_width;
            new_page.source_texture_height = block.source_height;
            new_page.packer = make_split_packer(side_length_px, side_length_px);
            fit(*new_page.packer, block);
            if block.packed_placement != null {
                array_add(*new_page.blocks, block);
                array_add(*pages, new_page);
            } else {
                log_error("Texture '%' (%x%) too large for %x% page",
                    block.path, block.source_width, block.source_height,
                    side_length_px, side_length_px);
            }
        }
    }

    metadata.side_length_px = side_length_px;
    for page, page_index: pages {
        for block: page.blocks {
            placement := block.packed_placement;
            if placement == null continue;
            append_packed_texture_using_allocator(
                *metadata,
                .{
                    top_left_x = placement.top_left_x,
                    top_left_y = placement.top_left_y,
                    w = block.source_width,
                    h = block.source_height,
                    path = block.path,
                    page_index = page_index,
                },
                result_allocator,
            );
        }
    }
    return metadata;
}

create :: (
    texture_paths: [] string,
    side_length_px: int = 0,
    compress_pages: bool = false,
) -> Packed_Textures {
    result: Packed_Textures;
    if texture_paths.count == 0 return result;

    side_length := side_length_px;
    if side_length <= 0 side_length = recommended_texture_pack_side_length(texture_paths);
    metadata := build_packed_texture_metadata(side_length, texture_paths);
    result.texture_placements = metadata.textures;

    maximum_page_index := -1;
    max_mipmap_level: s32;
    for texture: result.texture_placements {
        maximum_page_index = max(maximum_page_index, texture.page_index);
        mipmap_level: s32;
        smaller_dimension := min(texture.w, texture.h);
        while smaller_dimension > 1 {
            smaller_dimension /= 2;
            mipmap_level += 1;
        }
        max_mipmap_level = max(max_mipmap_level, mipmap_level);
    }
    page_count := cast(s32) (maximum_page_index + 1);
    if page_count == 0 return result;
    assert(page_count > 0 && side_length > 0 && max_mipmap_level >= 0);

    result.pages.page_count_per_mip_level = page_count;
    array_resize(*result.pages.mips, max_mipmap_level + 1);
    mip_side_length_px := cast(s32) side_length;
    for *level: result.pages.mips {
        level.page_side_length_px = mip_side_length_px;
        page_byte_count := cast(s64) mip_side_length_px
            * mip_side_length_px * RGBA8_BYTES_PER_PIXEL;
        // unused regions and levels beyond a page's last valid material mip stay zero.
        array_resize(*level.pixels, page_byte_count * page_count);
        mip_side_length_px = max(cast(s32) 1, mip_side_length_px / 2);
    }
    if !generate_all_mips(result.texture_placements, *result.pages) {
        deinit(*result);
        return .{};
    }
    if compress_pages compress_packed_texture_pages(*result);
    return result;
}

// compress the finished pages independently, preserving page and mip order.
compress_packed_texture_pages :: (textures: *Packed_Textures) {
    if textures.compressed return;
    assert(packed_textures_valid(textures));
    for *level: textures.pages.mips {
        side := level.page_side_length_px;
        blocks_per_axis := (cast(s64) side + BC3_BLOCK_SIDE_LENGTH_PX - 1) / BC3_BLOCK_SIDE_LENGTH_PX;
        source_page_byte_count := packed_texture_page_byte_count(side, false);
        compressed_page_byte_count := packed_texture_page_byte_count(side, true);
        compressed_pixels: [..] u8;
        array_resize(*compressed_pixels, compressed_page_byte_count * textures.pages.page_count_per_mip_level);
        for page: 0..textures.pages.page_count_per_mip_level - 1 {
            source := level.pixels.data + page * source_page_byte_count;
            destination := compressed_pixels.data + page * compressed_page_byte_count;
            for block_y: 0..blocks_per_axis - 1 {
                for block_x: 0..blocks_per_axis - 1 {
                    block: [BC3_BLOCK_SIDE_LENGTH_PX * BC3_BLOCK_SIDE_LENGTH_PX * RGBA8_BYTES_PER_PIXEL] u8 = ---;
                    for y: 0..BC3_BLOCK_SIDE_LENGTH_PX - 1 {
                        for x: 0..BC3_BLOCK_SIDE_LENGTH_PX - 1 {
                            // repeat edge pixels for partial blocks and the 2x2/1x1 mips.
                            source_x := min(block_x * BC3_BLOCK_SIDE_LENGTH_PX + x, side - 1);
                            source_y := min(block_y * BC3_BLOCK_SIDE_LENGTH_PX + y, side - 1);
                            memcpy(block.data + (y * BC3_BLOCK_SIDE_LENGTH_PX + x) * RGBA8_BYTES_PER_PIXEL,
                                source + (source_y * side + source_x) * RGBA8_BYTES_PER_PIXEL,
                                RGBA8_BYTES_PER_PIXEL);
                        }
                    }
                    compress_bc3_block(
                        destination + (block_y * blocks_per_axis + block_x) * BC3_BYTES_PER_BLOCK,
                        block.data);
                }
            }
        }
        array_free(level.pixels);
        level.pixels = compressed_pixels;
    }
    textures.compressed = true;
}

pack_texture_paths :: (
    side_length_px: int,
    force: bool,
    texture_paths: [..] string,
    progress_callback: Texture_Packing_Progress_Proc = null,
    progress_context: *void = null,
    max_texture_side_px := 0,
) {
    stbi_set_flip_vertically_on_load(0);
    defer stbi_set_flip_vertically_on_load(0);

    /*
    the following lines let me do new anywhere and not have to care about memory because
    after this function is done all required data is stored to file.
    */
    push_allocator(temp); // everything occurs on temporary storage
    auto_release_temp(); // when done temporary storage is reset, this is probably unnessary as someone's going to reset temp storage at some point.

    slog_scoped("pack_textures");

    if !force && !should_repack(
        texture_paths,
        side_length_px,
        progress_callback,
        progress_context,
        max_texture_side_px,
    ) {
        slog("All textures up to date, skipping repack.");
        return;
    }

    slog("Found % texture paths", texture_paths.count);
    for texture_paths  log("  %", it);

    texture_blocks: [..] *Texture_Block_To_Pack;

    for texture_paths {
        texture_packing_report_progress(progress_callback, progress_context);
        w, h, channels: s32;
        ok := stbi_info(temp_c_string(it), *w, *h, *channels);
        if !ok {
            log_error("Failed to read image info: %", it);
            continue;
        }

        block := New(Texture_Block_To_Pack);
        block.source_width = cast(int) w;
        block.source_height = cast(int) h;
        if max_texture_side_px > 0
            && (block.source_width > max_texture_side_px
                || block.source_height > max_texture_side_px) {
            if block.source_width >= block.source_height {
                block.source_height = max(
                    1,
                    block.source_height * max_texture_side_px / block.source_width,
                );
                block.source_width = max_texture_side_px;
            } else {
                block.source_width = max(
                    1,
                    block.source_width * max_texture_side_px / block.source_height,
                );
                block.source_height = max_texture_side_px;
            }
        }
        block.w = next_power_of_two_for_texture_packing(block.source_width);
        block.h = next_power_of_two_for_texture_packing(block.source_height);
        block.path = it;
        array_add(*texture_blocks, block);
    }

    quick_sort(texture_blocks, (a, b) => b.source_height - a.source_height);

    pages: [..] Texture_Page_Packing;

    for texture_blocks {
        texture_packing_report_progress(progress_callback, progress_context);
        block := it;
        placed := false;

        for * page: pages {
            if page.source_texture_width != block.source_width
                || page.source_texture_height != block.source_height continue;
            fit(*page.packer, block);
            if block.packed_placement != null {
                array_add(*page.blocks, block);
                placed = true;
                break;
            }
        }

        if !placed {
            new_page: Texture_Page_Packing;
            new_page.source_texture_width = block.source_width;
            new_page.source_texture_height = block.source_height;
            new_page.packer = make_split_packer(side_length_px, side_length_px);

            fit(*new_page.packer, block);
            if block.packed_placement != null {
                array_add(*new_page.blocks, block);
            } else {
                log_error("Texture '%' (%x%) too large for %x% page",
                    block.path, block.source_width, block.source_height,
                    side_length_px, side_length_px);
            }

            array_add(*pages, new_page);
        }
    }

    make_directory_if_it_does_not_exist("data/packed_textures");

    all_packed: [..] Texture_Placement;

    for page, page_index: pages {
        texture_packing_report_progress(progress_callback, progress_context);
        atlas_byte_count := side_length_px
            * side_length_px
            * RGBA8_BYTES_PER_PIXEL;
        image_data := cast(*u8) alloc(atlas_byte_count);
        memset(image_data, 0, cast(s64) atlas_byte_count);

        for block: page.blocks {
            texture_packing_report_progress(progress_callback, progress_context);
            placement := block.packed_placement;
            if placement == null continue;

            img_w, img_h, img_channels: s32;
            pixels := stbi_load(
                temp_c_string(block.path),
                *img_w,
                *img_h,
                *img_channels,
                RGBA8_CHANNEL_COUNT);
            if pixels == null {
                log_error("Failed to load image: %", block.path);
                continue;
            }
            defer stbi_image_free(pixels);  // stbi uses C malloc, still needed (doesn't care about jai context)

            packed_pixels := pixels;
            resized_pixels: *u8;
            if cast(int) img_w != block.source_width
                || cast(int) img_h != block.source_height {
                resized_pixels = cast(*u8) alloc(
                    block.source_width
                    * block.source_height
                    * RGBA8_BYTES_PER_PIXEL,
                );
                resize_ok := stbir_resize_uint8(
                    pixels,
                    img_w,
                    img_h,
                    0,
                    resized_pixels,
                    cast(s32) block.source_width,
                    cast(s32) block.source_height,
                    0,
                    RGBA8_CHANNEL_COUNT,
                );
                if resize_ok == 0 {
                    log_error("Failed to resize image for runtime atlas: %", block.path);
                    free(resized_pixels);
                    continue;
                }
                packed_pixels = resized_pixels;
            }

            for row: 0..block.source_height - 1 {
                src := packed_pixels
                    + row * block.source_width * RGBA8_BYTES_PER_PIXEL;
                dst_x := placement.top_left_x;
                dst_y := placement.top_left_y + row;
                dst := image_data
                    + (dst_y * side_length_px + dst_x)
                    * RGBA8_BYTES_PER_PIXEL;
                memcpy(
                    dst,
                    src,
                    cast(s64) (block.source_width * RGBA8_BYTES_PER_PIXEL));
            }
            if resized_pixels != null free(resized_pixels);

            array_add(*all_packed, Texture_Placement.{
                top_left_x = placement.top_left_x,
                top_left_y = placement.top_left_y,
                w = block.source_width,
                h = block.source_height,
                path = block.path,
                page_index = page_index,
            });
        }

        filename := tprint("data/packed_textures/packed_texture_%.png", page_index);
        stbi_write_png(
            temp_c_string(filename),
            xx side_length_px,
            xx side_length_px,
            RGBA8_CHANNEL_COUNT,
            image_data,
            xx (side_length_px * RGBA8_BYTES_PER_PIXEL)
        );
        log("Wrote atlas: % (% textures)", filename, page.blocks.count);
        texture_packing_report_progress(progress_callback, progress_context);
    }

    //  serialize metadata and write to file

    metadata: Packed_Texture_Layout;
    metadata.textures = all_packed;
    metadata.side_length_px = side_length_px;

    metadata_string, ok := struct_to_string_pretty(metadata);
    if ok {
        write_entire_file("data/packed_textures/packed_textures.metadata", metadata_string);
        log("Wrote metadata: data/packed_textures/packed_textures.metadata (% entries)", all_packed.count);
    } else {
        log_error("Failed to serialize packed texture metadata");
    }

    save_pack_manifest(
        texture_paths,
        side_length_px,
        progress_callback,
        progress_context,
        max_texture_side_px,
    );
}

pack_textures :: (side_length_px: int = 256, force: bool = false, texture_directory: string) {
    texture_paths := get_texture_paths(texture_directory);
    pack_texture_paths(side_length_px, force, texture_paths);
}

pack_textures :: (side_length_px: int = 256, force: bool = false, texture_directories: [] string) {
    texture_paths := get_texture_paths(texture_directories);
    pack_texture_paths(side_length_px, force, texture_paths);
}



// generate one texture's mips at a time and copy each directly into the finished pages.
generate_all_mips :: (
    texture_placements: [] Texture_Placement,
    pages: *Packed_Texture_Pages,
) -> bool {
    stbi_set_flip_vertically_on_load_thread(0);
    for texture: texture_placements {
        channels: s32;
        width, height: s32;
        decoded_pixels := stbi_load(
            temp_c_string(texture.path), *width, *height, *channels, RGBA8_CHANNEL_COUNT);
        if decoded_pixels == null {
            log_error("Failed to decode packed texture source: %", texture.path);
            return false;
        }
        defer stbi_image_free(decoded_pixels);
        if width != texture.w || height != texture.h {
            log_error("Packed texture source dimensions changed for %: metadata=%x%, decoded=%x%",
                texture.path, texture.w, texture.h, width, height);
            return false;
        }

        previous_pixels := decoded_pixels;
        mip_pixels: [..] u8;
        defer array_free(mip_pixels);
        mipmap_level: s32;
        while true {
            copy_texture_pixels_into_page(pages, texture, mipmap_level, previous_pixels, width, height);
            // the shader clamps this material to its final valid mip, even if
            // larger materials require more levels in the shared texture array.
            if min(width, height) == 1 break;

            next_width := max(cast(s32) 1, width / 2);
            next_height := max(cast(s32) 1, height / 2);
            next_pixels: [..] u8;
            array_resize(*next_pixels, cast(s64) next_width * next_height * RGBA8_BYTES_PER_PIXEL);
            // resize the individual texture, so neighbors on its page cannot bleed into it.
            resized := stbir_resize_uint8(
                previous_pixels, width, height, width * RGBA8_BYTES_PER_PIXEL,
                next_pixels.data, next_width, next_height, next_width * RGBA8_BYTES_PER_PIXEL,
                RGBA8_CHANNEL_COUNT);
            if resized == 0 {
                array_free(next_pixels);
                log_error("Failed to generate mip % for '%'", mipmap_level + 1, texture.path);
                return false;
            }
            array_free(mip_pixels);
            mip_pixels = next_pixels;
            previous_pixels = mip_pixels.data;
            width = next_width;
            height = next_height;
            mipmap_level += 1;
        }
    }
    return true;
}
