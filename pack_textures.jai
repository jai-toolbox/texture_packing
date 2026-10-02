#import "stb_image_write";
#import "stb_image";

#import "File_Utilities";
#import "String";

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
    
    /*
    todo in the future we might need recursion for when the texture you just packed is an atlas right?
    potentially not though. maybe all we need is a conversion function or something like that.
    */
}

Packed_Texture_Container :: struct {
    packer: Split_Packer;
    blocks: [..] *Texture_Block_To_Pack;
}

// everything could be unsigned maybe do it later when you're bored and read this comment
Packed_Texture :: struct {
    top_left_x: int;
    top_left_y: int;
    w: int;
    h: int;
    path: string;
    container_index: int;
}

#import "Sort";
#import "File";
#import "Math";
#import "tbx/serialize";

MAX_NUM_PACKED_TEXTURES :: 1024;

Packed_Textures_Metadata :: struct {
    side_length_px : int; // could be unsigned but probably doesn't matter
    textures: [..] Packed_Texture;
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
    destination_layer: s32;
}

Packed_Textures :: struct {
    metadata: Packed_Textures_Metadata;
    images: [..] Packed_Texture_Image;
    bounding_boxes: [..] Vector4;
    layer_count: s32;
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
    packed_texture: Packed_Texture,
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
build_packed_texture_metadata :: (
    side_length_px: int,
    texture_paths: [] string,
) -> Packed_Textures_Metadata {
    metadata: Packed_Textures_Metadata;
    result_allocator := context.allocator;
    push_allocator(temp);
    auto_release_temp();

    texture_blocks: [..] *Texture_Block_To_Pack;
    for path: texture_paths {
        w, h, channels: s32;
        if !stbi_info(temp_c_string(path), *w, *h, *channels) {
            log_error("Failed to read image info: %", path);
            continue;
        }

        block := New(Texture_Block_To_Pack);
        block.w = cast(int) w;
        block.h = cast(int) h;
        block.path = path;
        array_add(*texture_blocks, block);
    }

    quick_sort(texture_blocks, (a, b) => b.h - a.h);

    containers: [..] Packed_Texture_Container;
    for block: texture_blocks {
        placed := false;
        for *container: containers {
            fit(*container.packer, block);
            if block.packed_placement != null {
                array_add(*container.blocks, block);
                placed = true;
                break;
            }
        }

        if !placed {
            new_container: Packed_Texture_Container;
            new_container.packer = make_split_packer(side_length_px, side_length_px);
            fit(*new_container.packer, block);
            if block.packed_placement != null {
                array_add(*new_container.blocks, block);
                array_add(*containers, new_container);
            } else {
                log_error("Texture '%' (%x%) too large for %x% container",
                    block.path, block.w, block.h, side_length_px, side_length_px);
            }
        }
    }

    metadata.side_length_px = side_length_px;
    for container, container_index: containers {
        for block: container.blocks {
            placement := block.packed_placement;
            if placement == null continue;
            append_packed_texture_using_allocator(
                *metadata,
                .{
                    top_left_x = placement.top_left_x,
                    top_left_y = placement.top_left_y,
                    w = block.w,
                    h = block.h,
                    path = block.path,
                    container_index = container_index,
                },
                result_allocator,
            );
        }
    }
    return metadata;
}

load_packed_textures :: (
    texture_paths: [] string,
    side_length_px: int = 0,
) -> Packed_Textures {
    result: Packed_Textures;
    if texture_paths.count == 0 return result;

    side_length := side_length_px;
    if side_length <= 0 {
        side_length = recommended_texture_pack_side_length(texture_paths);
    }
    result.metadata = build_packed_texture_metadata(side_length, texture_paths);

    maximum_container_index := -1;
    for texture: result.metadata.textures {
        maximum_container_index = max(maximum_container_index, texture.container_index);
    }
    result.layer_count = cast(s32) (maximum_container_index + 1);
    if result.layer_count <= 0 return result;

    array_resize(*result.bounding_boxes, MAX_NUM_PACKED_TEXTURES);
    for texture, texture_index: result.metadata.textures {
        if texture_index >= MAX_NUM_PACKED_TEXTURES break;
        result.bounding_boxes[texture_index] = .{
            cast(float) texture.top_left_x / cast(float) side_length,
            cast(float) texture.top_left_y / cast(float) side_length,
            cast(float) texture.w / cast(float) side_length,
            cast(float) texture.h / cast(float) side_length,
        };
    }

    // stb exposes a thread-local override specifically for worker decoding.
    stbi_set_flip_vertically_on_load_thread(0);
    for texture: result.metadata.textures {
        image: Packed_Texture_Image;
        image.destination_x = cast(s32) texture.top_left_x;
        image.destination_y = cast(s32) texture.top_left_y;
        image.destination_layer = cast(s32) texture.container_index;

        channels: s32;
        decoded_pixels := stbi_load(
            temp_c_string(texture.path),
            *image.width,
            *image.height,
            *channels,
            4,
        );
        if decoded_pixels == null {
            log_error("Failed to decode packed texture source: %", texture.path);
            continue;
        }

        byte_count := cast(s64) image.width * cast(s64) image.height * 4;
        array_resize(*image.pixels, byte_count);
        memcpy(image.pixels.data, decoded_pixels, byte_count);
        stbi_image_free(decoded_pixels);
        array_add(*result.images, image);
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
        block.w = cast(int) w;
        block.h = cast(int) h;
        block.path = it;
        array_add(*texture_blocks, block);
    }

    quick_sort(texture_blocks, (a, b) => b.h - a.h);

    containers: [..] Packed_Texture_Container;

    for texture_blocks {
        block := it;
        placed := false;

        for * container: containers {
            fit(*container.packer, block);
            if block.packed_placement != null {
                array_add(*container.blocks, block);
                placed = true;
                break;
            }
        }

        if !placed {
            new_container: Packed_Texture_Container;
            new_container.packer = make_split_packer(side_length_px, side_length_px);

            fit(*new_container.packer, block);
            if block.packed_placement != null {
                array_add(*new_container.blocks, block);
            } else {
                log_error("Texture '%' (%x%) too large for %x% container",
                    block.path, block.w, block.h, side_length_px, side_length_px);
            }

            array_add(*containers, new_container);
        }
    }

    make_directory_if_it_does_not_exist("data/packed_textures");

    all_packed: [..] Packed_Texture;

    for container, container_idx: containers {
        atlas_byte_count := side_length_px * side_length_px * 4;
        image_data := cast(*u8) alloc(atlas_byte_count);
        memset(image_data, 0, cast(s64) atlas_byte_count);

        for block: container.blocks {
            placement := block.packed_placement;
            if placement == null continue;

            img_w, img_h, img_channels: s32;
            pixels := stbi_load(temp_c_string(block.path), *img_w, *img_h, *img_channels, 4);
            if pixels == null {
                log_error("Failed to load image: %", block.path);
                continue;
            }
            defer stbi_image_free(pixels);  // stbi uses C malloc, still needed (doesn't care about jai context)

            for row: 0..cast(int) img_h - 1 {
                src := pixels + row * img_w * 4;
                dst_x := placement.top_left_x;
                dst_y := placement.top_left_y + row;
                dst := image_data + (dst_y * side_length_px + dst_x) * 4;
                memcpy(dst, src, cast(s64)(img_w * 4));
            }

            array_add(*all_packed, Packed_Texture.{
                top_left_x = placement.top_left_x,
                top_left_y = placement.top_left_y,
                w = block.w,
                h = block.h,
                path = block.path,
                container_index = container_idx,
            });
        }

        filename := tprint("data/packed_textures/packed_texture_%.png", container_idx);
        stbi_write_png(
            temp_c_string(filename),
            xx side_length_px,
            xx side_length_px,
            4,
            image_data,
            xx (side_length_px * 4)
        );
        log("Wrote atlas: % (% textures)", filename, container.blocks.count);
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
