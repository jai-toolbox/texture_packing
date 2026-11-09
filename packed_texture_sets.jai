// Independent packs share a page size and format. Their pixels are never repacked:
// only the page indices in the concatenated placement table are adjusted.
// Capacity is a high-water mark: dropping a map removes its placements/used
// range, while spare (unreferenced) layers remain available for the next map.
Packed_Texture_Range :: struct {
    first_page: s32;
    page_count: s32;
    first_texture: int;
    texture_count: int;
}

truncate_packed_texture_layout :: (layout: *Packed_Texture_Layout, texture_count: int) {
    assert(texture_count >= 0 && texture_count <= layout.textures.count);
    for index: texture_count..layout.textures.count - 1 {
        free(layout.textures[index].path);
    }
    layout.textures.count = texture_count;
}

deinit :: (layout: *Packed_Texture_Layout) {
    truncate_packed_texture_layout(layout, 0);
    array_free(layout.textures);
    layout.* = .{};
}

append_packed_texture_layout :: (
    layout: *Packed_Texture_Layout,
    pack: *Packed_Textures,
    first_page: s32,
) -> range: Packed_Texture_Range, success: bool {
    range: Packed_Texture_Range;
    if !packed_textures_valid(pack) || first_page < 0 return .{}, false;
    side := pack.pages.mips[0].page_side_length_px;
    if layout.textures.count > 0 && layout.side_length_px != side return .{}, false;
    if layout.textures.count + pack.texture_placements.count > MAX_NUM_PACKED_TEXTURES return .{}, false;
    range = .{first_page, pack.pages.page_count_per_mip_level,
        layout.textures.count, pack.texture_placements.count};
    layout.side_length_px = side;
    for source: pack.texture_placements {
        placement := source;
        placement.path = copy_string(placement.path);
        placement.page_index += first_page;
        array_add(*layout.textures, placement);
    }
    return range, true;
}

// Drop a suffix without touching the persistent GPU layers or their indices.
retain_packed_texture_prefix :: (using ptr: *Packed_Texture_Rendering_Base) {
    truncate_packed_texture_layout(*metadata, persistent_texture_count);
    resident_page_count = persistent_page_count;
}

deinit :: (using ptr: *Packed_Texture_Rendering_Base) {
    if packed_texture_array_gl_id != 0 gl_delete_texture(packed_texture_array_gl_id);
    if retired_texture_array_gl_id != 0 gl_delete_texture(retired_texture_array_gl_id);
    if packed_texture_bounding_boxes_gl_id != 0 gl_delete_texture(packed_texture_bounding_boxes_gl_id);
    deinit(*metadata);
    ptr.* = .{};
}

// Call only with an idle resident set. Borrowed pixel buffers must survive until
// the budgeter finishes, including on cancellation. Growth copies the prefix on
// the GPU; map changes never read weapon packs again or upload weapon pixels.
replace_packed_texture_suffix_opengl :: (
    using ptr: *Packed_Texture_Rendering_Base,
    packs: [] Packed_Textures,
    budgeter: *GL_Budgeter = null,
) -> bool {
    if retired_texture_array_gl_id != 0 return false;
    new_layout: Packed_Texture_Layout;
    defer deinit(*new_layout);
    new_layout.side_length_px = metadata.side_length_px;
    for index: 0..persistent_texture_count - 1 {
        placement := metadata.textures[index];
        placement.path = copy_string(placement.path);
        array_add(*new_layout.textures, placement);
    }
    page_count := persistent_page_count;
    side := cast(s32) metadata.side_length_px;
    compressed := resident_compressed;
    for *pack: packs {
        if !packed_textures_valid(pack) return false;
        if page_count == 0 {
            side = pack.pages.mips[0].page_side_length_px;
            compressed = pack.compressed;
        }
        if pack.pages.mips[0].page_side_length_px != side || pack.compressed != compressed {
            log_error("Cannot combine packed textures with different page sizes or formats");
            return false;
        }
        range, appended := append_packed_texture_layout(*new_layout, pack, page_count);
        if !appended return false;
        page_count += range.page_count;
    }
    if page_count == 0 {
        retain_packed_texture_prefix(ptr);
        return true;
    }
    if side <= 0 || (side & (side - 1)) != 0 return false;
    maximum_layers, maximum_side: GLint;
    gl.glGetIntegerv(GL_MAX_ARRAY_TEXTURE_LAYERS, *maximum_layers);
    gl.glGetIntegerv(GL_MAX_TEXTURE_SIZE, *maximum_side);
    if page_count > maximum_layers || side > maximum_side return false;
    if compressed && !gl.GL_EXT_texture_compression_s3tc return false;

    grow := packed_texture_array_gl_id == 0 || page_count > page_capacity
        || metadata.side_length_px != side || resident_compressed != compressed;
    if grow && persistent_page_count > 0 && !packed_texture_copy_image_available() {
        log_error("Growing a resident packed texture array requires OpenGL copy-image support");
        return false;
    }

    gl_set_active_texture_unit(GL_TEXTURE0);
    gl_set_integer_pixel_storage_parameter(GL_UNPACK_ALIGNMENT, 1);
    gl_set_integer_pixel_storage_parameter(GL_UNPACK_ROW_LENGTH, 0);
    gl_set_integer_pixel_storage_parameter(GL_UNPACK_SKIP_PIXELS, 0);
    gl_set_integer_pixel_storage_parameter(GL_UNPACK_SKIP_ROWS, 0);
    if grow {
        retired_texture_array_gl_id = packed_texture_array_gl_id;
        packed_texture_array_gl_id = gl_create_texture();
        page_capacity = page_count;
        gl_bind_texture_to_binding_target_of_active_texture_unit(GL_TEXTURE_2D_ARRAY, packed_texture_array_gl_id);
        internal_format: GLint = xx GL_RGBA8;
        if compressed internal_format = xx GL_COMPRESSED_RGBA_S3TC_DXT5_EXT;
        mip_side := side;
        packed_texture_max_mip_level = 0;
        while true {
            gl_define_3d_image_for_texture_bound_to_binding_target_of_active_texture_unit(
                budgeter, GL_TEXTURE_2D_ARRAY, packed_texture_max_mip_level, internal_format,
                xx mip_side, xx mip_side, xx page_capacity, 0, GL_RGBA, GL_UNSIGNED_BYTE, null,
                packed_texture_page_byte_count(mip_side, compressed) * page_capacity);
            if mip_side == 1 break;
            mip_side /= 2;
            packed_texture_max_mip_level += 1;
        }
        // Copy only persistent pages, not the discarded map suffix. Each copy is
        // one page/mip so array growth also obeys the loading frame budget.
        if persistent_page_count > 0 {
            mip_side = side;
            for mip: 0..packed_texture_max_mip_level {
                for page: 0..persistent_page_count - 1 {
                    gl_copy_texture_array_page(budgeter, retired_texture_array_gl_id,
                        packed_texture_array_gl_id, xx mip, xx page, xx mip_side);
                }
                mip_side = max(cast(s32) 1, mip_side / 2);
            }
        }
        gl_set_integer_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        gl_set_integer_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        gl_set_integer_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        gl_set_integer_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        gl_set_integer_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MAX_LEVEL, packed_texture_max_mip_level);
    } else {
        gl_bind_texture_to_binding_target_of_active_texture_unit(GL_TEXTURE_2D_ARRAY, packed_texture_array_gl_id);
    }

    next_page := persistent_page_count;
    for *pack: packs {
        for level, mip: pack.pages.mips {
            if compressed {
                gl_update_compressed_3d_subimage_of_texture_bound_to_binding_target_of_active_texture_unit(
                    budgeter, GL_TEXTURE_2D_ARRAY, xx mip, 0, 0, next_page,
                    xx level.page_side_length_px, xx level.page_side_length_px, xx pack.pages.page_count_per_mip_level,
                    GL_COMPRESSED_RGBA_S3TC_DXT5_EXT, level.pixels.data, level.pixels.count,
                    BC3_BLOCK_SIDE_LENGTH_PX, BC3_BLOCK_SIDE_LENGTH_PX, BC3_BYTES_PER_BLOCK, .BORROW_UNTIL_COMPLETE);
            } else {
                gl_update_3d_subimage_of_texture_bound_to_binding_target_of_active_texture_unit(
                    budgeter, GL_TEXTURE_2D_ARRAY, xx mip, 0, 0, next_page,
                    xx level.page_side_length_px, xx level.page_side_length_px, xx pack.pages.page_count_per_mip_level,
                    GL_RGBA, GL_UNSIGNED_BYTE, level.pixels.data, level.pixels.count,
                    cast(s64) level.page_side_length_px * RGBA8_BYTES_PER_PIXEL, .BORROW_UNTIL_COMPLETE);
            }
        }
        next_page += pack.pages.page_count_per_mip_level;
    }
    gl_set_integer_pixel_storage_parameter(GL_UNPACK_ALIGNMENT, 4);
    deinit(*metadata);
    metadata = new_layout;
    new_layout = .{};
    resident_page_count = page_count;
    resident_compressed = compressed;

    bounding_boxes: [MAX_NUM_PACKED_TEXTURES] Vector4;
    for placement, index: metadata.textures {
        bounding_boxes[index] = .{cast(float) placement.top_left_x / side, cast(float) placement.top_left_y / side,
            cast(float) placement.w / side, cast(float) placement.h / side};
    }
    gl_set_active_texture_unit(GL_TEXTURE1);
    if packed_texture_bounding_boxes_gl_id == 0 packed_texture_bounding_boxes_gl_id = gl_create_texture();
    gl_bind_texture_to_binding_target_of_active_texture_unit(GL_TEXTURE_1D, packed_texture_bounding_boxes_gl_id);
    gl_define_1d_image_for_texture_bound_to_binding_target_of_active_texture_unit(
        budgeter, GL_TEXTURE_1D, 0, GL_RGBA32F, MAX_NUM_PACKED_TEXTURES, 0, GL_RGBA, GL_FLOAT,
        bounding_boxes.data, size_of(type_of(bounding_boxes)), .COPY);
    gl_set_integer_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(GL_TEXTURE_1D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    gl_set_integer_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(GL_TEXTURE_1D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    gl_set_integer_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(GL_TEXTURE_1D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    gl_set_active_texture_unit(GL_TEXTURE0);
    log("Packed texture set: % persistent + % map/new pages, % placements (capacity %)",
        persistent_page_count, page_count - persistent_page_count, metadata.textures.count, page_capacity);
    return true;
}

packed_texture_copy_image_available :: () -> bool {
    if gl.GL_VERSION_4_3 return true;
    if !gl.GL_VERSION_3_0 return false;
    count: GLint;
    gl.glGetIntegerv(GL_NUM_EXTENSIONS, *count);
    for index: 0..count - 1 {
        if to_string(gl.glGetStringi(GL_EXTENSIONS, xx index)) == "GL_ARB_copy_image" return true;
    }
    return false;
}
