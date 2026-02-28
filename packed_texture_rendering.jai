#import "Basic";
#import "Math";
#import "Hash_Table";
#import "GL";

#import "tbx/opengl";
#import "tbx/model_loading";


Packed_Texture_Lookup :: struct {
    metadata_index: s64;
    container_index: s64;
}

build_packed_texture_lookup_table :: (metadata: *Packed_Textures_Metadata) -> Table(string, Packed_Texture_Lookup) {
    table: Table(string, Packed_Texture_Lookup);
    for tex, idx: metadata.textures {
        table_add(*table, tex.path, Packed_Texture_Lookup.{
            metadata_index = cast(s64) idx,
            container_index = cast(s64) tex.container_index,
        });
    }
    return table;
}

find_packed_texture :: (lookup_table: *Table(string, Packed_Texture_Lookup), path: string) -> Packed_Texture_Lookup, bool {
    result, found := table_find(lookup_table, path);
    return result, found;
}

// you can combine this with a packed texture renderer to make life easier
Packed_Texture_Rendering_Base :: struct {

    metadata: Packed_Textures_Metadata;
    packed_texture_array_gl_id: GLuint;
    packed_texture_bounding_boxes_gl_id: GLuint;

}

bind_packed_textures :: (using ptrb : Packed_Texture_Rendering_Base) {
    // bind the packed texture array to texture unit 0 so the shader can sample from it
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D_ARRAY, packed_texture_array_gl_id);

    // bind the bounding box lookup texture to texture unit 1 so the shader can read uv regions
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_1D, packed_texture_bounding_boxes_gl_id);
}


init :: (using ptr: *Packed_Texture_Rendering_Base) {

    metadata_string, metadata_read_success := read_entire_file("data/packed_textures/packed_textures.metadata");
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

    // reset pixel store parameters to defaults so that no previous opengl state
    // from simp or other renderers corrupts our texture upload
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    glPixelStorei(GL_UNPACK_SKIP_PIXELS, 0);
    glPixelStorei(GL_UNPACK_SKIP_ROWS, 0);

    // make texture unit 0 the active unit so subsequent texture operations apply to it
    glActiveTexture(GL_TEXTURE0);

    // generate a single texture name for our 2d texture array
    glGenTextures(1, *packed_texture_array_gl_id);

    // bind the texture array so we can configure and upload data into it
    glBindTexture(GL_TEXTURE_2D_ARRAY, packed_texture_array_gl_id);

    // allocate gpu storage for the 2d texture array with one layer per container, rgba8 format
    glTexImage3D(GL_TEXTURE_2D_ARRAY, 0, GL_RGBA8, xx side, xx side, xx num_containers, 0, GL_RGBA, GL_UNSIGNED_BYTE, null);

    // use nearest neighbor filtering so pixel art and packed textures stay sharp
    glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MAG_FILTER, GL_NEAREST);

    // clamp to edge so we don't bleed into neighboring packed textures at boundaries
    glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    // flip images vertically on load because stbi loads with y=0 at the top
    // but opengl expects y=0 at the bottom
    stbi_set_flip_vertically_on_load(1);

    // load each container image from disk and upload it into its corresponding layer in the texture array
    for container_idx: 0..num_containers - 1 {
        container_path := tprint("data/packed_textures/packed_texture_%.png", container_idx);
        img_w, img_h, img_channels: s32;
        pixels := stbi_load(temp_c_string(container_path), *img_w, *img_h, *img_channels, 4);
        if pixels != null {
            if img_w != xx side || img_h != xx side {
                log_error("Container % has unexpected dimensions: %x% (expected %x%)", container_idx, img_w, img_h, side, side);
            }
            // upload this container's pixel data into the corresponding layer of the 2d texture array
            glTexSubImage3D(GL_TEXTURE_2D_ARRAY, 0, 0, 0, xx container_idx, xx img_w, xx img_h, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
            stbi_image_free(pixels);
        } else {
            log_error("Failed to load container image: %", container_path);
        }
    }

    // reset flip state so we don't affect other stbi_load calls elsewhere
    stbi_set_flip_vertically_on_load(0);

    // restore default alignment after we're done uploading
    glPixelStorei(GL_UNPACK_ALIGNMENT, 4);

    // now build the 1d texture that stores bounding boxes for each packed texture
    // each texel is a vec4 holding the normalized uv region within its container
    MAX_NUM_TEXTURES :: 1024;
    bounding_boxes: [MAX_NUM_TEXTURES] Vector4;

    for tex, tex_idx: metadata.textures {
        if tex_idx >= MAX_NUM_TEXTURES {
            log_error("Too many packed textures (%), exceeds MAX_NUM_TEXTURES", metadata.textures.count);
            break;
        }
        u_min := cast(float) tex.top_left_x / cast(float) side;
        v_min := cast(float) tex.top_left_y / cast(float) side;
        u_max := cast(float) (tex.top_left_x + tex.w) / cast(float) side;
        v_max := cast(float) (tex.top_left_y + tex.h) / cast(float) side;
        bounding_boxes[tex_idx] = .{u_min, v_min, u_max, v_max};
    }

    // make texture unit 1 the active unit for the bounding box texture
    glActiveTexture(GL_TEXTURE1);

    // generate a texture name for the 1d bounding box lookup texture
    glGenTextures(1, *packed_texture_bounding_boxes_gl_id);

    // bind it so we can configure and upload data
    glBindTexture(GL_TEXTURE_1D, packed_texture_bounding_boxes_gl_id);

    // upload the bounding box data as a 1d texture with rgba32f so each texel holds four floats
    glTexImage1D(GL_TEXTURE_1D, 0, GL_RGBA32F, MAX_NUM_TEXTURES, 0, GL_RGBA, GL_FLOAT, bounding_boxes.data);

    // use nearest filtering since we're looking up exact texel values by index
    glTexParameteri(GL_TEXTURE_1D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_1D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);

    // clamp to edge to avoid any out of bounds sampling issues
    glTexParameteri(GL_TEXTURE_1D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);


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
    glUseProgram(renderer.shader_program_gl_handle);
    set_packed_textures_uniform(*renderer, 0);
    set_packed_texture_bounding_boxes_uniform(*renderer, 1);
    glUseProgram(0);
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

        // walk all faces, triangulate them via fan, and build vertex and index data
        // we fully de-index the obj data so each face vertex becomes its own vertex in the renderable

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

                // texture coordinate
                tc: Vector2;
                if fv.texture_coordinate_index >= 0 && fv.texture_coordinate_index < model.obj_data.all_texture_coordinates.count {
                    tc = model.obj_data.all_texture_coordinates[fv.texture_coordinate_index];
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

            // fan triangulation: for an n-gon with vertices [0..n-1]
            // produce triangles (0,1,2), (0,2,3), ..., (0,n-2,n-1)
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
