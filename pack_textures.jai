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
            array_add(paths, copy_string(info.full_name));
        }
    };

    visit_files(directory, recursive = true, *image_file_paths, visitor, visit_directories = true);

    return image_file_paths;
}

Texture_Block_To_Pack :: struct { 
    using #as base : Block_To_Pack;

    path: string;
    
    // todo in the future we might need recursion for when the texture you just packed is an atlas right?
    // potentially not though. maybe all we need is a conversion function or something like that.
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
#import "tbx/serialize";

Packed_Textures_Metadata :: struct {
    side_length_px : int; // could be unsigned but probably doesn't matter
    textures: [..] Packed_Texture;
}

pack_textures :: (side_length_px: int = 256, force: bool = false, texture_directory: string) {

    // the following lines let me do new anywhere and not have to care about memory because
    // after this function is done all required data is stored to file.
    push_allocator(temp); // everything occurs on temporary storage
    auto_release_temp(); // when done temporary storage is reset, this is probably unnessary as someone's going to reset temp storage at some point.

    slog_scoped("pack_textures");

    texture_paths := get_texture_paths(texture_directory);

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
