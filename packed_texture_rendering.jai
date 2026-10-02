#import "Basic";
#import "Math";
#import "Hash_Table";
#import "GL";

#import "tbx/opengl";
#import "tbx/model_loading";
#import "tbx/assets";

USING_OPENGL :: true;
PACKED_TEXTURE_VERBOSE_LOGGING :: false;

Packed_Texture_Lookup :: struct {
    metadata_index: s32; // what is this again?
    container_index: s32;
}


downsampling_will_not_mix_packed_texture_with_neighbors :: (
    texture: Packed_Texture,
    base_level_pixels_per_downsampled_texel: int,
) -> bool {
    texture_has_at_least_one_downsampled_texel_per_axis :=
        base_level_pixels_per_downsampled_texel <= texture.w
        && base_level_pixels_per_downsampled_texel <= texture.h;

    all_texture_edges_are_on_downsampled_texel_boundaries :=
        texture.top_left_x % base_level_pixels_per_downsampled_texel == 0
        && texture.top_left_y % base_level_pixels_per_downsampled_texel == 0
        && (texture.top_left_x + texture.w) % base_level_pixels_per_downsampled_texel == 0
        && (texture.top_left_y + texture.h) % base_level_pixels_per_downsampled_texel == 0;

    return texture_has_at_least_one_downsampled_texel_per_axis
        && all_texture_edges_are_on_downsampled_texel_boundaries;
}

build_packed_texture_lookup_table :: (metadata: *Packed_Textures_Metadata) -> Table(string, Packed_Texture_Lookup) {
    table: Table(string, Packed_Texture_Lookup);
    for tex, idx: metadata.textures {
        table_add(*table, tex.path, Packed_Texture_Lookup.{
            metadata_index = cast(s32) idx,
            container_index = cast(s32) tex.container_index,
        });
    }
    return table;
}

find_packed_texture :: (lookup_table: *Table(string, Packed_Texture_Lookup), path: string) -> Packed_Texture_Lookup, bool {
    found, result := table_find(lookup_table, path);
    return result, found;
}

init_from_texture_paths :: (
    using ptr: *Packed_Texture_Rendering_Base,
    texture_paths: [] string,
    side_length_px: int,
) {
    slog_scoped("init packed textures directly from sources");

    metadata = build_packed_texture_metadata(side_length_px, texture_paths);

    max_container_index := -1;
    for texture: metadata.textures {
        max_container_index = max(max_container_index, texture.container_index);
    }
    num_containers := max_container_index + 1;
    if num_containers <= 0 return;

    gl_set_integer_pixel_storage_parameter(GL_UNPACK_ALIGNMENT, 1);
    gl_set_integer_pixel_storage_parameter(GL_UNPACK_ROW_LENGTH, 0);
    gl_set_integer_pixel_storage_parameter(GL_UNPACK_SKIP_PIXELS, 0);
    gl_set_integer_pixel_storage_parameter(GL_UNPACK_SKIP_ROWS, 0);
    gl_set_active_texture_unit(GL_TEXTURE0);

    packed_texture_array_gl_id = gl_create_texture();
    gl_bind_texture_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_2D_ARRAY,
        packed_texture_array_gl_id,
    );
    gl_define_3d_image_for_texture_bound_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_2D_ARRAY,
        0,
        GL_RGBA8,
        xx side_length_px,
        xx side_length_px,
        xx num_containers,
        0,
        GL_RGBA,
        GL_UNSIGNED_BYTE,
        null,
    );
    gl_set_integer_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    gl_set_integer_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    gl_set_integer_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_2D_ARRAY, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    gl_set_integer_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_2D_ARRAY, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    stbi_set_flip_vertically_on_load(0);
    for texture: metadata.textures {
        img_w, img_h, img_channels: s32;
        pixels := stbi_load(
            temp_c_string(texture.path),
            *img_w,
            *img_h,
            *img_channels,
            4,
        );
        if pixels == null {
            log_error("Failed to load packed texture source: %", texture.path);
            continue;
        }

        gl_update_3d_subimage_of_texture_bound_to_binding_target_of_active_texture_unit(
            GL_TEXTURE_2D_ARRAY,
            0,
            xx texture.top_left_x,
            xx texture.top_left_y,
            xx texture.container_index,
            xx img_w,
            xx img_h,
            1,
            GL_RGBA,
            GL_UNSIGNED_BYTE,
            pixels,
        );
        stbi_image_free(pixels);
    }
    stbi_set_flip_vertically_on_load(0);
    gl_set_integer_pixel_storage_parameter(GL_UNPACK_ALIGNMENT, 4);

    MAX_NUM_TEXTURES :: 1024;
    bounding_boxes: [MAX_NUM_TEXTURES] Vector4;
    for texture, texture_index: metadata.textures {
        if texture_index >= MAX_NUM_TEXTURES break;
        bounding_boxes[texture_index] = .{
            cast(float) texture.top_left_x / cast(float) side_length_px,
            cast(float) texture.top_left_y / cast(float) side_length_px,
            cast(float) texture.w / cast(float) side_length_px,
            cast(float) texture.h / cast(float) side_length_px,
        };
    }

    gl_set_active_texture_unit(GL_TEXTURE1);
    packed_texture_bounding_boxes_gl_id = gl_create_texture();
    gl_bind_texture_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_1D,
        packed_texture_bounding_boxes_gl_id,
    );
    gl_define_1d_image_for_texture_bound_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_1D,
        0,
        GL_RGBA32F,
        MAX_NUM_TEXTURES,
        0,
        GL_RGBA,
        GL_FLOAT,
        bounding_boxes.data,
    );
    gl_set_integer_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_1D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    gl_set_integer_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_1D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    gl_set_integer_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_1D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    gl_set_active_texture_unit(GL_TEXTURE0);

    log("Uploaded % source textures directly into % GPU container(s)",
        metadata.textures.count, num_containers);
}

/*
Consumes the metadata ownership from a complete CPU Packed_Textures value and
installs its backend resources. When a budgeter is supplied, decoded image and
bounding-box memory remain owned by textures until all budgeted work completes.
*/
install_packed_textures_opengl :: (
    using ptr: *Packed_Texture_Rendering_Base,
    textures: *Packed_Textures,
    budgeter: *GL_Budgeter = null,
    compress_packed_texture_array_on_gpu: bool = false,
) -> bool {
    if textures.layer_count <= 0 || textures.metadata.textures.count == 0 {
        return false;
    }

    metadata = textures.metadata;
    textures.metadata = .{};
    side_length_px := metadata.side_length_px;

    gl_set_integer_pixel_storage_parameter(GL_UNPACK_ALIGNMENT, 1);
    gl_set_integer_pixel_storage_parameter(GL_UNPACK_ROW_LENGTH, 0);
    gl_set_integer_pixel_storage_parameter(GL_UNPACK_SKIP_PIXELS, 0);
    gl_set_integer_pixel_storage_parameter(GL_UNPACK_SKIP_ROWS, 0);
    gl_set_active_texture_unit(GL_TEXTURE0);

    packed_texture_array_gl_id = gl_create_texture();
    gl_bind_texture_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_2D_ARRAY,
        packed_texture_array_gl_id,
    );
    texture_array_internal_format: GLint = cast(GLint) GL_RGBA8;
    if compress_packed_texture_array_on_gpu {
        texture_array_internal_format = cast(GLint) GL_COMPRESSED_RGBA;
    }
    gl_define_3d_image_for_texture_bound_to_binding_target_of_active_texture_unit(
        budgeter,
        GL_TEXTURE_2D_ARRAY,
        0,
        texture_array_internal_format,
        xx side_length_px,
        xx side_length_px,
        xx textures.layer_count,
        0,
        GL_RGBA,
        GL_UNSIGNED_BYTE,
        null,
        cast(s64) side_length_px * side_length_px * textures.layer_count * 4,
    );
    gl_set_integer_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    gl_set_integer_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    gl_set_integer_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_2D_ARRAY, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    gl_set_integer_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_2D_ARRAY, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    for image: textures.images {
        gl_update_3d_subimage_of_texture_bound_to_binding_target_of_active_texture_unit(
            budgeter,
            GL_TEXTURE_2D_ARRAY,
            0,
            image.destination_x,
            image.destination_y,
            image.destination_layer,
            xx image.width,
            xx image.height,
            1,
            GL_RGBA,
            GL_UNSIGNED_BYTE,
            image.pixels.data,
            image.pixels.count,
            cast(s64) image.width * 4,
            .BORROW_UNTIL_COMPLETE,
        );
    }
    gl_set_integer_pixel_storage_parameter(GL_UNPACK_ALIGNMENT, 4);

    gl_set_active_texture_unit(GL_TEXTURE1);
    packed_texture_bounding_boxes_gl_id = gl_create_texture();
    gl_bind_texture_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_1D,
        packed_texture_bounding_boxes_gl_id,
    );
    gl_define_1d_image_for_texture_bound_to_binding_target_of_active_texture_unit(
        budgeter,
        GL_TEXTURE_1D,
        0,
        GL_RGBA32F,
        MAX_NUM_PACKED_TEXTURES,
        0,
        GL_RGBA,
        GL_FLOAT,
        textures.bounding_boxes.data,
        textures.bounding_boxes.count * size_of(Vector4),
        .BORROW_UNTIL_COMPLETE,
    );
    gl_set_integer_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_1D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    gl_set_integer_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_1D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    gl_set_integer_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_1D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    gl_set_active_texture_unit(GL_TEXTURE0);

    if budgeter {
        log("Added % decoded source textures to the GL budgeter for % GPU container(s)",
            textures.images.count, textures.layer_count);
    } else {
        log("Uploaded % decoded source textures directly into % GPU container(s)",
            textures.images.count, textures.layer_count);
    }
    return true;
}

/*
call this only after every budgeted packed-texture upload has completed. Mipmap
generation reads the completed base level, so it cannot be queued ahead of the
subimage operations that populate that level.

in the future I just want to compute mipmaps manually and save them that way
because we cannot split this function ane make it run at a realtime rate unfortunately.
*/
finalize_installed_packed_textures_opengl :: (
    using ptr: *Packed_Texture_Rendering_Base,
    generate_mipmaps: bool,
) {
    if packed_texture_array_gl_id == 0 return;

    gl_set_active_texture_unit(GL_TEXTURE0);
    gl_bind_texture_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_2D_ARRAY,
        packed_texture_array_gl_id,
    );

    if generate_mipmaps {
        max_safe_mip_level := 30;
        for texture: metadata.textures {
            texture_safe_mip_level := 0;
            base_level_pixels_per_downsampled_texel := 2;
            while downsampling_will_not_mix_packed_texture_with_neighbors(
                texture,
                base_level_pixels_per_downsampled_texel,
            ) {
                texture_safe_mip_level += 1;
                base_level_pixels_per_downsampled_texel *= 2;
            }
            max_safe_mip_level = min(
                max_safe_mip_level,
                texture_safe_mip_level);
        }

        if max_safe_mip_level > 0 {
            packed_texture_max_mip_level = cast(s32) max_safe_mip_level;
            gl_generate_mipmap_levels_for_texture_bound_to_binding_target_of_active_texture_unit(
                GL_TEXTURE_2D_ARRAY);
            gl_set_integer_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(
                GL_TEXTURE_2D_ARRAY,
                GL_TEXTURE_MAX_LEVEL,
                packed_texture_max_mip_level);
            gl_set_integer_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(
                GL_TEXTURE_2D_ARRAY,
                GL_TEXTURE_MIN_FILTER,
                GL_LINEAR_MIPMAP_LINEAR);
            if gl.GL_EXT_texture_filter_anisotropic {
                maximum_anisotropy: GLfloat;
                gl_get_float_values_for_state_parameter(
                    GL_MAX_TEXTURE_MAX_ANISOTROPY_EXT,
                    *maximum_anisotropy);
                gl_set_float_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(
                    GL_TEXTURE_2D_ARRAY,
                    GL_TEXTURE_MAX_ANISOTROPY_EXT,
                    min(4.0, maximum_anisotropy));
            }
            log("Packed material textures use % safe mip level(s)",
                packed_texture_max_mip_level);
        }
    }

    texture_is_compressed: GLint;
    base_level_compressed_bytes: GLint;
    gl_get_integer_parameter_for_texture_level_bound_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_2D_ARRAY,
        0,
        GL_TEXTURE_COMPRESSED,
        *texture_is_compressed,
    );
    if texture_is_compressed != 0 {
        gl_get_integer_parameter_for_texture_level_bound_to_binding_target_of_active_texture_unit(
            GL_TEXTURE_2D_ARRAY,
            0,
            GL_TEXTURE_COMPRESSED_IMAGE_SIZE,
            *base_level_compressed_bytes,
        );
        log("Packed material GPU base level is block compressed: % MiB",
            cast(float64) base_level_compressed_bytes / (1024.0 * 1024.0));
    } else {
        log("Packed material GPU storage is uncompressed");
    }
}

// you can combine this with a packed texture renderer to make life easier
Packed_Texture_Rendering_Base :: struct {

    metadata: Packed_Textures_Metadata;
    packed_texture_array_gl_id: GLuint;
    packed_texture_bounding_boxes_gl_id: GLuint;
    packed_texture_max_mip_level: s32;

}

bind_packed_textures :: (using ptrb : Packed_Texture_Rendering_Base) {
    // bind the packed texture array to texture unit 0 so the shader can sample from it
    gl_set_active_texture_unit(GL_TEXTURE0);
    gl_bind_texture_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_2D_ARRAY,
        packed_texture_array_gl_id,
    );

    // bind the bounding box lookup texture to texture unit 1 so the shader can read uv regions
    gl_set_active_texture_unit(GL_TEXTURE1);
    gl_bind_texture_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_1D,
        packed_texture_bounding_boxes_gl_id,
    );
}


init :: (
    using ptr: *Packed_Texture_Rendering_Base,
    generate_mipmaps: bool = false,
    compress_packed_texture_array_on_gpu: bool = false,
) {

    slog_scoped("init packed_texture_rendering_base");

    metadata_read_success, metadata_string := load_asset("data/packed_textures/packed_textures.metadata");
    if !metadata_read_success {
        log_error("Failed to read packed textures metadata file");
        return;
    }

    metadata_result, metadata_ok, bytes_read := from_string(metadata_string, Packed_Textures_Metadata);
    if !metadata_ok {
        log_error("Failed to deserialize packed textures metadata (parsed % bytes before failure)", bytes_read);
        return;
    }
    metadata = metadata_result;

    log("Loaded packed texture metadata with % entries", metadata.textures.count);

    max_container_index := -1;
    for metadata.textures {
        if it.container_index > max_container_index
            max_container_index = it.container_index;
    }
    num_containers := max_container_index + 1;

    if num_containers <= 0 {
        log_error("No packed texture containers found in metadata");
        return;
    }

    side := metadata.side_length_px;

    log("Container dimensions: %x%, % containers", side, side, num_containers);

    /*
    reset pixel store parameters to defaults so that no previous opengl state
    from simp or other renderers corrupts our texture upload
    */
    gl_set_integer_pixel_storage_parameter(GL_UNPACK_ALIGNMENT, 1);
    gl_set_integer_pixel_storage_parameter(GL_UNPACK_ROW_LENGTH, 0);
    gl_set_integer_pixel_storage_parameter(GL_UNPACK_SKIP_PIXELS, 0);
    gl_set_integer_pixel_storage_parameter(GL_UNPACK_SKIP_ROWS, 0);

    // make texture unit 0 the active unit so subsequent texture operations apply to it
    gl_set_active_texture_unit(GL_TEXTURE0);

    // generate a single texture name for our 2d texture array
    packed_texture_array_gl_id = gl_create_texture();

    // bind the texture array so we can configure and upload data into it
    gl_bind_texture_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_2D_ARRAY,
        packed_texture_array_gl_id,
    );

    texture_array_internal_format: GLint = cast(GLint) GL_RGBA8;
    if compress_packed_texture_array_on_gpu {
        // let the driver choose a supported block-compressed RGBA format while
        // still accepting the unpacked PNG pixels uploaded below.
        texture_array_internal_format = cast(GLint) GL_COMPRESSED_RGBA;
    }
    gl_define_3d_image_for_texture_bound_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_2D_ARRAY,
        0,
        texture_array_internal_format,
        xx side,
        xx side,
        xx num_containers,
        0,
        GL_RGBA,
        GL_UNSIGNED_BYTE,
        null,
    );

    // pbr material textures should interpolate smoothly; nearest filtering makes them look blocky.
    gl_set_integer_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    gl_set_integer_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

    // clamp to edge so we don't bleed into neighboring packed textures at boundaries
    gl_set_integer_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_2D_ARRAY, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    gl_set_integer_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_2D_ARRAY, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    /*
    keep packed atlas uploads in the same row order used by the source
    textures and by the direct glTF texture upload path. Flipping the atlas
    here mirrors every packed sub-rectangle vertically, which makes glTF UVs
    sample the wrong part of shared packed layers.
    */
    stbi_set_flip_vertically_on_load(0);

    // load each container image from disk and upload it into its corresponding layer in the texture array
    for container_idx: 0..num_containers - 1 {
        container_path := tprint("data/packed_textures/packed_texture_%.png", container_idx);
        img_w, img_h, img_channels: s32;
        image_loaded, image_data := load_asset(container_path);
        pixels: *u8;
        if image_loaded {
            pixels = stbi_load_from_memory(image_data.data, xx image_data.count, *img_w, *img_h, *img_channels, 4);
        }
        if pixels != null {
            if img_w != xx side || img_h != xx side {
                log_error("Container % has unexpected dimensions: %x% (expected %x%)", container_idx, img_w, img_h, side, side);
            }
            // upload this container's pixel data into the corresponding layer of the 2d texture array
            gl_update_3d_subimage_of_texture_bound_to_binding_target_of_active_texture_unit(
                GL_TEXTURE_2D_ARRAY,
                0,
                0,
                0,
                xx container_idx,
                xx img_w,
                xx img_h,
                1,
                GL_RGBA,
                GL_UNSIGNED_BYTE,
                pixels,
            );
            stbi_image_free(pixels);
        } else {
            log_error("Failed to load container image: %", container_path);
        }
    }

    /*
    mip levels dramatically reduce cache pressure for distant surfaces.
    Only expose levels where every packed rectangle remains aligned to the
    mip texel grid. That prevents glGenerateMipmap from averaging adjacent
    packed materials together while it downsamples the container.
    */
    if generate_mipmaps {
        max_safe_mip_level := 30;
        for texture: metadata.textures {
            texture_safe_mip_level := 0;
            base_level_pixels_per_downsampled_texel := 2;
            while downsampling_will_not_mix_packed_texture_with_neighbors(
                texture,
                base_level_pixels_per_downsampled_texel,
            ) {
                texture_safe_mip_level += 1;
                base_level_pixels_per_downsampled_texel *= 2;
            }
            max_safe_mip_level = min(
                max_safe_mip_level,
                texture_safe_mip_level);
        }

        if max_safe_mip_level > 0 {
            packed_texture_max_mip_level = cast(s32) max_safe_mip_level;
            gl_generate_mipmap_levels_for_texture_bound_to_binding_target_of_active_texture_unit(
                GL_TEXTURE_2D_ARRAY);
            gl_set_integer_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(
                GL_TEXTURE_2D_ARRAY,
                GL_TEXTURE_MAX_LEVEL,
                packed_texture_max_mip_level);
            gl_set_integer_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(
                GL_TEXTURE_2D_ARRAY,
                GL_TEXTURE_MIN_FILTER,
                GL_LINEAR_MIPMAP_LINEAR);
            if gl.GL_EXT_texture_filter_anisotropic {
                maximum_anisotropy: GLfloat;
                gl_get_float_values_for_state_parameter(
                    GL_MAX_TEXTURE_MAX_ANISOTROPY_EXT,
                    *maximum_anisotropy);
                gl_set_float_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(
                    GL_TEXTURE_2D_ARRAY,
                    GL_TEXTURE_MAX_ANISOTROPY_EXT,
                    min(4.0, maximum_anisotropy));
            }
            log("Packed material textures use % safe mip level(s)",
                packed_texture_max_mip_level);
        }
    }

    texture_is_compressed: GLint;
    base_level_compressed_bytes: GLint;
    gl_get_integer_parameter_for_texture_level_bound_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_2D_ARRAY,
        0,
        GL_TEXTURE_COMPRESSED,
        *texture_is_compressed,
    );
    if texture_is_compressed != 0 {
        gl_get_integer_parameter_for_texture_level_bound_to_binding_target_of_active_texture_unit(
            GL_TEXTURE_2D_ARRAY,
            0,
            GL_TEXTURE_COMPRESSED_IMAGE_SIZE,
            *base_level_compressed_bytes,
        );
        log("Packed material GPU base level is block compressed: % MiB",
            cast(float64) base_level_compressed_bytes / (1024.0 * 1024.0));
    } else {
        log("Packed material GPU storage is uncompressed");
    }

    // reset flip state so we don't affect other stbi_load calls elsewhere
    stbi_set_flip_vertically_on_load(0);

    // restore default alignment after we're done uploading
    gl_set_integer_pixel_storage_parameter(GL_UNPACK_ALIGNMENT, 4);

    /*
    now build the 1d texture that stores bounding boxes for each packed texture
    each texel is a vec4 holding the normalized uv region within its container
    */
    MAX_NUM_TEXTURES :: 1024;
    bounding_boxes: [MAX_NUM_TEXTURES] Vector4;

    for tex, tex_idx: metadata.textures {
        if tex_idx >= MAX_NUM_TEXTURES {
            log_error("Too many packed textures (%), exceeds MAX_NUM_TEXTURES", metadata.textures.count);
            break;
        }

        u_min  := cast(float) tex.top_left_x / cast(float) side;
        v_min  := cast(float) tex.top_left_y / cast(float) side;
        width  := cast(float) tex.w / cast(float) side;
        height := cast(float) tex.h / cast(float) side;

        bounding_boxes[tex_idx] = .{u_min, v_min, width, height};

        #if PACKED_TEXTURE_VERBOSE_LOGGING {
            slog("bbox[%] path='%' container=% | top_left=(%,%) size=(%x%) | uv: u_min=% v_min=% width=% height=%",
                tex_idx, tex.path, tex.container_index,
                tex.top_left_x, tex.top_left_y, tex.w, tex.h,
                u_min, v_min, width, height);
        }
    }

    // make texture unit 1 the active unit for the bounding box texture
    gl_set_active_texture_unit(GL_TEXTURE1);

    // generate a texture name for the 1d bounding box lookup texture
    packed_texture_bounding_boxes_gl_id = gl_create_texture();

    // bind it so we can configure and upload data
    gl_bind_texture_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_1D,
        packed_texture_bounding_boxes_gl_id,
    );

    // upload the bounding box data as a 1d texture with rgba32f so each texel holds four floats
    gl_define_1d_image_for_texture_bound_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_1D,
        0,
        GL_RGBA32F,
        MAX_NUM_TEXTURES,
        0,
        GL_RGBA,
        GL_FLOAT,
        bounding_boxes.data,
    );

    // use nearest filtering since we're looking up exact texel values by index
    gl_set_integer_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_1D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    gl_set_integer_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_1D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);

    // clamp to edge to avoid any out of bounds sampling issues
    gl_set_integer_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_1D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);


    log("Packed texture rendering initialized: % textures across % containers", metadata.textures.count, num_containers);
}


Packed_Texture_Rendering :: struct {
    renderables: [..] Camera_Per_Object_Transforms_Packed_Texture_Renderable;
    renderer: Camera_Per_Object_Transforms_Packed_Texture_Renderer;

    using #as base : Packed_Texture_Rendering_Base;
}

init :: (using ptr : * Packed_Texture_Rendering) {
    init(*renderer);
    init(*base);

    // tell the shader which texture units correspond to which samplers
    gl_set_active_shader_program(renderer.shader_program_gl_handle);
    set_packed_textures_uniform(*renderer, 0);
    set_packed_texture_bounding_boxes_uniform(*renderer, 1);
    gl_clear_active_shader_program();
}

load_model :: (using ptr: *Packed_Texture_Rendering, base_path: string) {
    model := load_wavefront_model(base_path);
    new_renderables := load_wavefront_into_packed_texture_renderables(*model, *metadata, *renderer);
    for new_renderables {
        array_add(*renderables, it);
    }
}


load_wavefront_into_packed_texture_renderables :: (
    model: *Wavefront_Model,
    metadata: *Packed_Textures_Metadata,
    renderer: *Camera_Per_Object_Transforms_Packed_Texture_Renderer
) -> [..] Camera_Per_Object_Transforms_Packed_Texture_Renderable {

    renderables: [..] Camera_Per_Object_Transforms_Packed_Texture_Renderable;

    lookup_table := build_packed_texture_lookup_table(metadata);

    for * obj: model.obj_data.all_objects {

        renderable: Camera_Per_Object_Transforms_Packed_Texture_Renderable;

        // figure out which packed texture this object uses from its material's diffuse map
        material := find_material_for_object(model, obj);

        tex_lookup: Packed_Texture_Lookup;
        has_texture := false;

        if material != null && material.map_diffuse.count > 0 {
            resolved_path := resolve_texture_path(model, material.map_diffuse);
            tex_lookup, has_texture = find_packed_texture(*lookup_table, resolved_path);
            if !has_texture {
                log_error("Could not find packed texture for '%' (resolved: '%') on object '%'",
                    material.map_diffuse, resolved_path, obj.name);
            }
        }

        /*
        walk all faces, triangulate them via fan, and build vertex and index data
        we fully de-index the obj data so each face vertex becomes its own vertex in the renderable
        */

        vertex_count: u32 = 0;

        for * face: obj.faces {
            num_face_verts := face.face_vertices.count;
            if num_face_verts < 3 continue;

            // record where this face's vertices start in the renderable arrays
            first_index_for_face := vertex_count;

            // emit all vertices for this face
            for fv_idx: 0..num_face_verts - 1 {
                fv := face.face_vertices[fv_idx];

                // position
                pos: Vector3;
                if fv.position_index >= 0 && fv.position_index < model.obj_data.all_positions.count {
                    pos = model.obj_data.all_positions[fv.position_index];
                }
                array_add(*renderable.positions, pos);

                tc: Vector2;
                if fv.texture_coordinate_index >= 0 && fv.texture_coordinate_index < model.obj_data.all_texture_coordinates.count {
                    tc = model.obj_data.all_texture_coordinates[fv.texture_coordinate_index];

                    if has_texture {
                        /*
                        the metadata stores: top_left_x, top_left_y, w, h in pixel space
                        convert the model's [0,1] uvs into the sub-region of the packed texture
                        */
                        side := cast(float) metadata.side_length_px;

                        u_min  := cast(float) metadata.textures[tex_lookup.metadata_index].top_left_x / side;
                        v_min  := cast(float) metadata.textures[tex_lookup.metadata_index].top_left_y / side;
                        width  := cast(float) metadata.textures[tex_lookup.metadata_index].w / side;
                        height := cast(float) metadata.textures[tex_lookup.metadata_index].h / side;



                        if USING_OPENGL v_min = 1.0 - v_min - height;

                        /* 
                        at this point in time if we're using opengl then we know the following:
                        - the image was flipped on load to match opengl's y=0 at the bottom of the image
                        - v_min was flipped to match the flipped image
                        - the obj spec says that uv is the bottom left of the image, because everything is adjust this works.
                        */

                        // remap from [0,1] individual texture space into packed atlas space
                        tc.x = u_min + tc.x * width;
                        tc.y = v_min + tc.y * height;
                    }
                }
                array_add(*renderable.texture_coordinates, tc);

                // which layer in the packed texture array this vertex samples from
                if has_texture {
                    array_add(*renderable.packed_texture_index, tex_lookup.container_index);
                } else {
                    array_add(*renderable.packed_texture_index, 0);
                }

                // which entry in the bounding box 1d texture this vertex uses
                if has_texture {
                    array_add(*renderable.packed_texture_bounding_box_index, tex_lookup.metadata_index);
                } else {
                    array_add(*renderable.packed_texture_bounding_box_index, 0);
                }

                vertex_count += 1;
            }

            /*
            fan triangulation: for an n-gon with vertices [0..n-1]
            produce triangles (0,1,2), (0,2,3), ..., (0,n-2,n-1)
            */
            for tri: 0..cast(int)(num_face_verts - 3) {
                array_add(*renderable.indices, first_index_for_face);
                array_add(*renderable.indices, first_index_for_face + cast(u32)(tri + 1));
                array_add(*renderable.indices, first_index_for_face + cast(u32)(tri + 2));
            }
        }

        // send this object's geometry to the gpu
        success := buffer_object(renderer, *renderable);
        if !success {
            log_error("Failed to buffer object '%' into packed texture renderer", obj.name);
        }

        array_add(*renderables, renderable);
    }

    return renderables;
}

// passing a pointer because of render.
render :: (using packed_texture_rendering : *Packed_Texture_Rendering) {

    bind_packed_textures(base);

    // draw all queued packed texture geometry
    render(*renderer);
}
