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

Packed_Texture_Page :: struct {
    packer: Split_Packer;
    blocks: [..] *Texture_Block_To_Pack;
    source_texture_width: int;
    source_texture_height: int;
}

// everything could be unsigned maybe do it later when you're bored and read this comment
// its later and I read this comment and I dont care lol
Packed_Texture_Metadata :: struct {
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
PACKED_TEXTURE_ASSET_VERSION :: 1;

Packed_Textures_Metadata :: struct {
    side_length_px : int; // could be unsigned but probably doesn't matter
    textures: [..] Packed_Texture_Metadata;
}

/*
The canonical CPU representation of packed textures. It contains decoded
pixels and placement metadata, but no graphics-API objects. This lets asset
jobs perform image decoding and layout work without an OpenGL or Vulkan
context.
*/
Packed_Texture_Image :: struct {
    pixels: [..] u8;
    width: s32;
    height: s32;
    destination_x: s32;
    destination_y: s32;
    page_index: s32;
    mipmap_level: s32;
}


/*

Right now this is doing way more than just what it says here. Given a collection of images
it packs them so that images of the same dimensions end up on the same page, there will
never be "mixed" resolution images on the same page. So given a bunch of images you get a
specific sequences of pages for those images. 

On top of this we are also generating a parallel identical page sequence for different mip levels

So we have a page sequence for mip level 0 (original textures), then one for mip level 1, etc...

We should probably do some cleanup here to make this more obvious later.

*/

Packed_Textures :: struct {
    version: u32 = PACKED_TEXTURE_ASSET_VERSION;
    metadata: Packed_Textures_Metadata;
    
    images: [..] Packed_Texture_Image;
    // .{top_left_x, top_left_y, width, height} in [0,1]^4
    bounding_boxes: [..] Vector4;
    // every mip level of the OpenGL texture array has this same page count.
    page_count: s32;
    // this is the deepest mip needed by any page. pages containing smaller
    // source textures become invalid sooner and are clamped in the shader.
    max_mipmap_level: s32;
}

deinit :: (textures: *Packed_Textures) {
    for *image: textures.images array_free(image.pixels);
    array_free(textures.images);
    array_free(textures.bounding_boxes);

    for *texture: textures.metadata.textures {
        if texture.path.count > 0 free(texture.path);
    }
    array_free(textures.metadata.textures);
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
    if textures.metadata.textures.count != texture_paths.count return false;
    for path: texture_paths {
        found := false;
        for texture: textures.metadata.textures {
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
    if textures.version != PACKED_TEXTURE_ASSET_VERSION return false;
    if textures.metadata.side_length_px <= 0 return false;
    if textures.metadata.textures.count <= 0
        || textures.metadata.textures.count > MAX_NUM_PACKED_TEXTURES return false;
    if textures.page_count <= 0 return false;
    if textures.images.count < textures.metadata.textures.count return false;
    if textures.bounding_boxes.count != MAX_NUM_PACKED_TEXTURES return false;
    for image: textures.images {
        if image.width <= 0 || image.height <= 0 return false;
        if image.mipmap_level < 0
            || image.mipmap_level > textures.max_mipmap_level return false;
        expected_byte_count := cast(s64) image.width
            * image.height
            * RGBA8_BYTES_PER_PIXEL;
        if image.pixels.count != expected_byte_count return false;
    }
    return true;
}

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
    metadata: *Packed_Textures_Metadata,
    packed_texture: Packed_Texture_Metadata,
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
build_packed_texture_metadata :: (side_length_px: int, texture_paths: [] string) -> Packed_Textures_Metadata {
    metadata: Packed_Textures_Metadata;
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

    pages: [..] Packed_Texture_Page;
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
            new_page: Packed_Texture_Page;
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

load_packed_textures :: (texture_paths: [] string, side_length_px: int = 0) -> Packed_Textures {
    result: Packed_Textures;
    if texture_paths.count == 0 return result;

    side_length := side_length_px;
    if side_length <= 0 {
        side_length = recommended_texture_pack_side_length(texture_paths);
    }
    result.metadata = build_packed_texture_metadata(side_length, texture_paths);

    maximum_page_index := -1;
    for texture: result.metadata.textures {
        maximum_page_index = max(maximum_page_index, texture.page_index);
    }
    result.page_count = cast(s32) (maximum_page_index + 1);
    if result.page_count <= 0 return result;

    array_resize(*result.bounding_boxes, MAX_NUM_PACKED_TEXTURES);
    for texture, texture_index: result.metadata.textures {
        if texture_index >= MAX_NUM_PACKED_TEXTURES break;
        // normalized, not pixels.
        result.bounding_boxes[texture_index] = .{
            cast(float) texture.top_left_x / cast(float) side_length,
            cast(float) texture.top_left_y / cast(float) side_length,
            cast(float) texture.w / cast(float) side_length,
            cast(float) texture.h / cast(float) side_length,
        };
    }

    // each source texture is downsampled independently, so no mip texel can
    // average pixels from a neighboring packed texture.
    stbi_set_flip_vertically_on_load_thread(0);
    for original_texture: result.metadata.textures {
        channels: s32;
        base_width, base_height: s32;
        decoded_pixels := stbi_load(
            temp_c_string(original_texture.path),
            *base_width,
            *base_height,
            *channels,
            RGBA8_CHANNEL_COUNT,
        );
        if decoded_pixels == null {
            log_error("Failed to decode packed texture source: %", original_texture.path);
            continue;
        }
        if base_width != original_texture.w || base_height != original_texture.h {
            log_error(
                "Packed texture source dimensions changed for %: metadata=%x%, decoded=%x%",
                original_texture.path,
                original_texture.w,
                original_texture.h,
                base_width,
                base_height);
            stbi_image_free(decoded_pixels);
            continue;
        }

        base_image: Packed_Texture_Image;
        base_image.width = base_width;
        base_image.height = base_height;
        base_image.destination_x = cast(s32) original_texture.top_left_x;
        base_image.destination_y = cast(s32) original_texture.top_left_y;
        base_image.page_index = cast(s32) original_texture.page_index;
        base_image.mipmap_level = 0;
        base_byte_count := cast(s64) base_width
            * base_height
            * RGBA8_BYTES_PER_PIXEL;
        array_resize(*base_image.pixels, base_byte_count);
        memcpy(base_image.pixels.data, decoded_pixels, base_byte_count);
        stbi_image_free(decoded_pixels);
        array_add(*result.images, base_image);

        previous_image_index := result.images.count - 1;
        mipmap_level: s32 = 0;
        // generate this source texture independently until its own 1x1 mip.
        // no image is uploaded for this region at deeper shared-array levels;
        // the sampling shader prevents this page from reaching those levels.
        while min(result.images[previous_image_index].width, result.images[previous_image_index].height) > 1 {
            // on the first iteration this is the base image created above;
            // otherwise it is the last mip level generated below.
            previous := *result.images[previous_image_index];
            mipmap_level += 1;

            image: Packed_Texture_Image;
            image.width = max(cast(s32) 1, previous.width / 2);
            image.height = max(cast(s32) 1, previous.height / 2);

            image.destination_x = cast(s32) (original_texture.top_left_x >> mipmap_level);
            image.destination_y = cast(s32) (original_texture.top_left_y >> mipmap_level);

            image.page_index = cast(s32) original_texture.page_index;
            image.mipmap_level = mipmap_level;
            byte_count := cast(s64) image.width * image.height * RGBA8_BYTES_PER_PIXEL;

            array_resize(*image.pixels, byte_count);

            resize_success := stbir_resize_uint8(
                previous.pixels.data,
                previous.width,
                previous.height,
                previous.width * RGBA8_BYTES_PER_PIXEL,
                image.pixels.data,
                image.width,
                image.height,
                image.width * RGBA8_BYTES_PER_PIXEL,
                RGBA8_CHANNEL_COUNT);
            assert(resize_success != 0,
                "Failed to generate mip % for '%'",
                mipmap_level,
                original_texture.path);
            array_add(*result.images, image);
            previous_image_index = result.images.count - 1;
        }
        result.max_mipmap_level = max(result.max_mipmap_level, mipmap_level);
    }

    return result;
}

pack_texture_paths :: (side_length_px: int, force: bool, texture_paths: [..] string) {
    stbi_set_flip_vertically_on_load(0);
    defer stbi_set_flip_vertically_on_load(0);

    /*
    the following lines let me do new anywhere and not have to care about memory because
    after this function is done all required data is stored to file.
    */
    push_allocator(temp); // everything occurs on temporary storage
    auto_release_temp(); // when done temporary storage is reset, this is probably unnessary as someone's going to reset temp storage at some point.

    slog_scoped("pack_textures");

    if !force && !should_repack(texture_paths, side_length_px) {
        slog("All textures up to date, skipping repack.");
        return;
    }

    slog("Found % texture paths", texture_paths.count);
    for texture_paths  log("  %", it);

    texture_blocks: [..] *Texture_Block_To_Pack;

    for texture_paths {
        w, h, channels: s32;
        ok := stbi_info(temp_c_string(it), *w, *h, *channels);
        if !ok {
            log_error("Failed to read image info: %", it);
            continue;
        }

        block := New(Texture_Block_To_Pack);
        block.source_width = cast(int) w;
        block.source_height = cast(int) h;
        block.w = next_power_of_two_for_texture_packing(block.source_width);
        block.h = next_power_of_two_for_texture_packing(block.source_height);
        block.path = it;
        array_add(*texture_blocks, block);
    }

    quick_sort(texture_blocks, (a, b) => b.source_height - a.source_height);

    pages: [..] Packed_Texture_Page;

    for texture_blocks {
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
            new_page: Packed_Texture_Page;
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

    all_packed: [..] Packed_Texture_Metadata;

    for page, page_index: pages {
        atlas_byte_count := side_length_px
            * side_length_px
            * RGBA8_BYTES_PER_PIXEL;
        image_data := cast(*u8) alloc(atlas_byte_count);
        memset(image_data, 0, cast(s64) atlas_byte_count);

        for block: page.blocks {
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

            for row: 0..cast(int) img_h - 1 {
                src := pixels + row * img_w * RGBA8_BYTES_PER_PIXEL;
                dst_x := placement.top_left_x;
                dst_y := placement.top_left_y + row;
                dst := image_data
                    + (dst_y * side_length_px + dst_x)
                    * RGBA8_BYTES_PER_PIXEL;
                memcpy(
                    dst,
                    src,
                    cast(s64) (img_w * RGBA8_BYTES_PER_PIXEL));
            }

            array_add(*all_packed, Packed_Texture_Metadata.{
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
    }

    //  serialize metadata and write to file

    metadata: Packed_Textures_Metadata;
    metadata.textures = all_packed;
    metadata.side_length_px = side_length_px;

    metadata_string, ok := struct_to_string_pretty(metadata);
    if ok {
        write_entire_file("data/packed_textures/packed_textures.metadata", metadata_string);
        log("Wrote metadata: data/packed_textures/packed_textures.metadata (% entries)", all_packed.count);
    } else {
        log_error("Failed to serialize packed texture metadata");
    }

    save_pack_manifest(texture_paths, side_length_px);
}

pack_textures :: (side_length_px: int = 256, force: bool = false, texture_directory: string) {
    texture_paths := get_texture_paths(texture_directory);
    pack_texture_paths(side_length_px, force, texture_paths);
}

pack_textures :: (side_length_px: int = 256, force: bool = false, texture_directories: [] string) {
    texture_paths := get_texture_paths(texture_directories);
    pack_texture_paths(side_length_px, force, texture_paths);
}
