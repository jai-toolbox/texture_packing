// bc3 (dxt5) compression based on the S3TC format described in the article below.
// reference: McCabe and Brothers, DirectX 6 Texture Map Compression (1998), pp. 42-46.
// https://media.gdcvault.com/GD_Mag_Archives/GDM_August_1998.pdf#page=26

#import "Basic";
#import "Math";

BC3_BLOCK_SIDE_LENGTH_PX :: 4;
BC3_BYTES_PER_BLOCK :: 16;

// encode one 4x4 RGBA8 block into 16 bytes of BC3, including its alpha channel.
compress_bc3_block :: (destination: *u8, rgba_pixels: *u8, high_quality: bool = true) {
    colors: [16] RGB_Color;
    for *color, pixel_index: colors {
        pixel := rgba_pixels + pixel_index * 4;
        color.* = .{pixel[0], pixel[1], pixel[2]};
    }
    compress_alpha_block(destination, rgba_pixels);
    compress_color_block(destination + 8, colors, high_quality);
}

#scope_file

// widen input bytes once, so color calculations can use ordinary signed arithmetic.
RGB_Color :: struct {
    r, g, b: s32;
}

// #run generates these constants during compilation; the executable contains
// only the finished tables, with no startup initialization or worker-thread writes.
NORMALIZED_ROUNDING_THRESHOLDS_FOR_5_BIT_COLOR_CHANNEL :: #run generate_color_quantization_midpoints(5);
NORMALIZED_ROUNDING_THRESHOLDS_FOR_6_BIT_COLOR_CHANNEL :: #run generate_color_quantization_midpoints(6);
BEST_5_BIT_ENDPOINT_PAIRS_BY_8_BIT_COLOR_CHANNEL_VALUE :: #run generate_optimal_color_endpoints(5);
BEST_6_BIT_ENDPOINT_PAIRS_BY_8_BIT_COLOR_CHANNEL_VALUE :: #run generate_optimal_color_endpoints(6);

// the four palette entries use these first-endpoint weights out of three.
FIRST_ENDPOINT_WEIGHTS_BY_COLOR_INDEX :: s32.[3, 0, 2, 1];

generate_color_quantization_midpoints :: ($BIT_COUNT: int) -> [1 << BIT_COUNT] float32 {
    #assert(BIT_COUNT == 5 || BIT_COUNT == 6);
    result: [1 << BIT_COUNT] float32;
    // these fixed-point multipliers expand a 5-bit or 6-bit channel to 8 bits.
    dequantization_multiplier := ifx BIT_COUNT == 5 then 33 * 4 else 65;
    for endpoint: 0..result.count - 2 {
        lower_value := (endpoint * dequantization_multiplier) >> 4;
        upper_value := ((endpoint + 1) * dequantization_multiplier) >> 4;
        // average the neighboring values and normalize by 255, rounding the
        // thresholds to six decimal places to preserve existing encoded output.
        midpoint_millionths := ((lower_value + upper_value) * 1_000_000 + 255) / 510;
        result[endpoint] = cast(float32) (cast(float64) midpoint_millionths / 1_000_000.0);
    }
    result[result.count - 1] = 1.0;
    return result;
}

// search for optimal endpoints, keeping the first pair when errors are equal.
generate_optimal_color_endpoints :: ($BIT_COUNT: int) -> [256] [2] u8 {
    #assert(BIT_COUNT == 5 || BIT_COUNT == 6);
    result: [256] [2] u8;
    endpoint_count :: 1 << BIT_COUNT;
    dequantization_multiplier := ifx BIT_COUNT == 5 then 33 * 4 else 65;
    for channel_value: 0..255 {
        best_error := 256 * 100;
        for minimum_endpoint: 0..endpoint_count - 1 {
            minimum_value := (minimum_endpoint * dequantization_multiplier) >> 4;
            for maximum_endpoint: 0..endpoint_count - 1 {
                maximum_value := (maximum_endpoint * dequantization_multiplier) >> 4;
                interpolated_value := (2 * maximum_value + minimum_value) / 3;
                error := abs(interpolated_value - channel_value) * 100;
                // add a 3% penalty for wide pairs to allow for hardware interpolation error.
                error += abs(maximum_value - minimum_value) * 3;
                if error < best_error {
                    best_error = error;
                    result[channel_value][0] = cast(u8) maximum_endpoint;
                    result[channel_value][1] = cast(u8) minimum_endpoint;
                }
            }
        }
    }
    return result;
}

compress_color_block :: (destination: *u8, colors: [] RGB_Color, high_quality: bool) {
    first_endpoint, second_endpoint: u16;
    color_indices: u32;
    solid_color := true;
    for color: colors {
        if color.r != colors[0].r || color.g != colors[0].g || color.b != colors[0].b {
            solid_color = false;
            break;
        }
    }

    if solid_color {
        first_endpoint, second_endpoint = find_solid_color_endpoints(colors[0]);
        // palette entry 2 blends two thirds of the first endpoint with one third of the second.
        color_indices = 0xaaaaaaaa;
    } else {
        first_endpoint, second_endpoint = find_initial_color_endpoints(colors);
        if first_endpoint != second_endpoint {
            palette := create_color_palette(first_endpoint, second_endpoint);
            color_indices = find_closest_color_indices(colors, palette);
        }

        refinement_count := ifx high_quality then 2 else 1;
        for 0..refinement_count - 1 {
            previous_indices := color_indices;
            refined_first, refined_second := refine_color_endpoints(
                colors, color_indices);
            if refined_first != first_endpoint || refined_second != second_endpoint {
                first_endpoint = refined_first;
                second_endpoint = refined_second;
                if first_endpoint == second_endpoint {
                    color_indices = 0;
                    break;
                }
                palette := create_color_palette(first_endpoint, second_endpoint);
                color_indices = find_closest_color_indices(colors, palette);
            }
            if color_indices == previous_indices break;
        }
    }

    if first_endpoint < second_endpoint {
        swap(*first_endpoint, *second_endpoint);
        // swapping the endpoints also swaps palette entries 0/1 and 2/3.
        color_indices ^= 0x55555555;
    }
    write_little_endian(destination, first_endpoint, 2);
    write_little_endian(destination + 2, second_endpoint, 2);
    write_little_endian(destination + 4, color_indices, 4);
}

find_solid_color_endpoints :: (color: RGB_Color) -> u16, u16 {
    red_endpoints := BEST_5_BIT_ENDPOINT_PAIRS_BY_8_BIT_COLOR_CHANNEL_VALUE[color.r];
    green_endpoints := BEST_6_BIT_ENDPOINT_PAIRS_BY_8_BIT_COLOR_CHANNEL_VALUE[color.g];
    blue_endpoints := BEST_5_BIT_ENDPOINT_PAIRS_BY_8_BIT_COLOR_CHANNEL_VALUE[color.b];
    return pack_rgb565(red_endpoints[0], green_endpoints[0], blue_endpoints[0]),
        pack_rgb565(red_endpoints[1], green_endpoints[1], blue_endpoints[1]);
}

create_color_palette :: (first_endpoint: u16, second_endpoint: u16) -> [4] RGB_Color {
    first := unpack_rgb565(first_endpoint);
    second := unpack_rgb565(second_endpoint);
    return .[first, second, blend_color_one_third(first, second), blend_color_one_third(second, first)];
}

blend_color_one_third :: (first: RGB_Color, second: RGB_Color) -> RGB_Color {
    return .{
        (2 * first.r + second.r) / 3,
        (2 * first.g + second.g) / 3,
        (2 * first.b + second.b) / 3,
    };
}

project_color_onto_axis :: inline (color: RGB_Color, axis: RGB_Color) -> s32 {
    return color.r * axis.r + color.g * axis.g + color.b * axis.b;
}

find_closest_color_indices :: (colors: [] RGB_Color, palette: [] RGB_Color) -> u32 {
    axis := RGB_Color.{
        palette[0].r - palette[1].r,
        palette[0].g - palette[1].g,
        palette[0].b - palette[1].b,
    };
    palette_projections: [4] s32;
    for color, index: palette palette_projections[index] = project_color_onto_axis(color, axis);
    // compare doubled projections with sums of neighboring palette projections.
    // this avoids division when choosing which side of each midpoint a color lies on.
    first_threshold := palette_projections[1] + palette_projections[3];
    middle_threshold := palette_projections[3] + palette_projections[2];
    last_threshold := palette_projections[2] + palette_projections[0];

    result: u32;
    for color, pixel_index: colors {
        projection := project_color_onto_axis(color, axis) * 2;
        color_index: u32;
        if projection < middle_threshold {
            color_index = 3;
            if projection < first_threshold color_index = 1;
        } else if projection < last_threshold {
            color_index = 2;
        }
        result |= color_index << (pixel_index * 2);
    }
    return result;
}

// refit the endpoints to the current palette assignments using least squares.
refine_color_endpoints :: (
    colors: [] RGB_Color,
    color_indices: u32,
) -> u16, u16 {
    // when every pixel uses the same palette entry, the least-squares matrix is singular.
    if (color_indices ^ (color_indices << 2)) < 4 {
        average: RGB_Color;
        for color: colors {
            average.r += color.r;
            average.g += color.g;
            average.b += color.b;
        }
        average.r = (average.r + 8) / 16;
        average.g = (average.g + 8) / 16;
        average.b = (average.b + 8) / 16;
        first_endpoint, second_endpoint := find_solid_color_endpoints(average);
        return first_endpoint, second_endpoint;
    }

    first_weight_squared_sum, second_weight_squared_sum, weight_product_sum: s32;
    first_color_sum, total_color_sum: RGB_Color;
    remaining_indices := color_indices;
    for color: colors {
        color_index := remaining_indices & 3;
        remaining_indices >>= 2;
        first_weight := FIRST_ENDPOINT_WEIGHTS_BY_COLOR_INDEX[color_index];
        second_weight := 3 - first_weight;
        first_weight_squared_sum += first_weight * first_weight;
        second_weight_squared_sum += second_weight * second_weight;
        weight_product_sum += first_weight * second_weight;
        first_color_sum.r += first_weight * color.r;
        first_color_sum.g += first_weight * color.g;
        first_color_sum.b += first_weight * color.b;
        total_color_sum.r += color.r;
        total_color_sum.g += color.g;
        total_color_sum.b += color.b;
    }
    second_color_sum := RGB_Color.{
        3 * total_color_sum.r - first_color_sum.r,
        3 * total_color_sum.g - first_color_sum.g,
        3 * total_color_sum.b - first_color_sum.b,
    };
    determinant := first_weight_squared_sum * second_weight_squared_sum
        - weight_product_sum * weight_product_sum;
    // 3/255 accounts for the palette weights and converts byte values to normalized colors.
    scale: float32 = 0.011764706 / cast(float32) determinant;
    first_red := (first_color_sum.r * second_weight_squared_sum
        - second_color_sum.r * weight_product_sum) * scale;
    first_green := (first_color_sum.g * second_weight_squared_sum
        - second_color_sum.g * weight_product_sum) * scale;
    first_blue := (first_color_sum.b * second_weight_squared_sum
        - second_color_sum.b * weight_product_sum) * scale;
    second_red := (second_color_sum.r * first_weight_squared_sum
        - first_color_sum.r * weight_product_sum) * scale;
    second_green := (second_color_sum.g * first_weight_squared_sum
        - first_color_sum.g * weight_product_sum) * scale;
    second_blue := (second_color_sum.b * first_weight_squared_sum
        - first_color_sum.b * weight_product_sum) * scale;
    return pack_normalized_rgb565(first_red, first_green, first_blue),
        pack_normalized_rgb565(second_red, second_green, second_blue);
}

pack_normalized_rgb565 :: (red: float32, green: float32, blue: float32) -> u16 {
    return pack_rgb565(
        quantize_normalized_color_channel(red, 5),
        quantize_normalized_color_channel(green, 6),
        quantize_normalized_color_channel(blue, 5));
}

quantize_normalized_color_channel :: (value: float32, $BIT_COUNT: int) -> u16 {
    #assert(BIT_COUNT == 5 || BIT_COUNT == 6);
    value = clamp(value, 0.0, 1.0);
    maximum_value :: (1 << BIT_COUNT) - 1;
    result := cast(u16) (value * maximum_value);
    #if BIT_COUNT == 5 {
        if value > NORMALIZED_ROUNDING_THRESHOLDS_FOR_5_BIT_COLOR_CHANNEL[result] result += 1;
    } else {
        if value > NORMALIZED_ROUNDING_THRESHOLDS_FOR_6_BIT_COLOR_CHANNEL[result] result += 1;
    }
    return result;
}

find_initial_color_endpoints :: (colors: [] RGB_Color) -> u16, u16 {
    mean: RGB_Color;
    minimum := colors[0];
    maximum := colors[0];
    for color: colors {
        mean.r += color.r;
        mean.g += color.g;
        mean.b += color.b;
        minimum.r = min(minimum.r, color.r);
        minimum.g = min(minimum.g, color.g);
        minimum.b = min(minimum.b, color.b);
        maximum.r = max(maximum.r, color.r);
        maximum.g = max(maximum.g, color.g);
        maximum.b = max(maximum.b, color.b);
    }
    mean.r = (mean.r + 8) / 16;
    mean.g = (mean.g + 8) / 16;
    mean.b = (mean.b + 8) / 16;

    // the six independent entries of the symmetric RGB covariance matrix.
    covariance: [6] s32;
    for color: colors {
        red := color.r - mean.r;
        green := color.g - mean.g;
        blue := color.b - mean.b;
        covariance[0] += red * red;
        covariance[1] += red * green;
        covariance[2] += red * blue;
        covariance[3] += green * green;
        covariance[4] += green * blue;
        covariance[5] += blue * blue;
    }
    normalized_covariance: [6] float32;
    for value, index: covariance normalized_covariance[index] = cast(float32) value / 255.0;

    // power iteration finds the main direction of color variation in this block.
    direction := Vector3.{
        cast(float32) (maximum.r - minimum.r),
        cast(float32) (maximum.g - minimum.g),
        cast(float32) (maximum.b - minimum.b),
    };
    for 0..3 {
        direction = .{
            direction.x * normalized_covariance[0] + direction.y * normalized_covariance[1]
                + direction.z * normalized_covariance[2],
            direction.x * normalized_covariance[1] + direction.y * normalized_covariance[3]
                + direction.z * normalized_covariance[4],
            direction.x * normalized_covariance[2] + direction.y * normalized_covariance[4]
                + direction.z * normalized_covariance[5],
        };
    }
    magnitude: float64 = max(abs(direction.x), max(abs(direction.y), abs(direction.z)));
    axis := RGB_Color.{299, 587, 114};
    if magnitude >= 4.0 {
        scale := 512.0 / magnitude;
        axis = .{
            cast(s32) (direction.x * scale),
            cast(s32) (direction.y * scale),
            cast(s32) (direction.z * scale),
        };
    }

    minimum_color := colors[0];
    maximum_color := colors[0];
    minimum_projection := project_color_onto_axis(colors[0], axis);
    maximum_projection := minimum_projection;
    for color: colors {
        projection := project_color_onto_axis(color, axis);
        if projection < minimum_projection {
            minimum_projection = projection;
            minimum_color = color;
        }
        if projection > maximum_projection {
            maximum_projection = projection;
            maximum_color = color;
        }
    }
    return pack_color_as_rgb565(maximum_color), pack_color_as_rgb565(minimum_color);
}

pack_color_as_rgb565 :: (color: RGB_Color) -> u16 {
    return pack_rgb565(
        quantize_byte_color_channel(color.r, 31),
        quantize_byte_color_channel(color.g, 63),
        quantize_byte_color_channel(color.b, 31));
}

quantize_byte_color_channel :: (value: s32, maximum_value: s32) -> u16 {
    rounded_product := value * maximum_value + 128;
    return cast(u16) ((rounded_product + (rounded_product >> 8)) >> 8);
}

pack_rgb565 :: (red: u16, green: u16, blue: u16) -> u16 {
    return (red << 11) | (green << 5) | blue;
}

unpack_rgb565 :: (color: u16) -> RGB_Color {
    red: s32 = (color >> 11) & 31;
    green: s32 = (color >> 5) & 63;
    blue: s32 = color & 31;
    return .{(red * 33) >> 2, (green * 65) >> 4, (blue * 33) >> 2};
}

compress_alpha_block :: (destination: *u8, rgba_pixels: *u8) {
    minimum: s32 = rgba_pixels[3];
    maximum := minimum;
    for pixel_index: 1..15 {
        alpha: s32 = rgba_pixels[pixel_index * 4 + 3];
        minimum = min(minimum, alpha);
        maximum = max(maximum, alpha);
    }
    destination[0] = cast(u8) maximum;
    destination[1] = cast(u8) minimum;

    alpha_range := maximum - minimum;
    bias := ifx alpha_range < 8 then alpha_range - 1 else alpha_range / 2 + 2;
    bias -= minimum * 7;
    packed_indices: u64;
    for pixel_index: 0..15 {
        alpha: s32 = rgba_pixels[pixel_index * 4 + 3];
        scaled_alpha := alpha * 7 + bias;
        palette_step := 0;
        if scaled_alpha >= alpha_range * 4 {
            palette_step += 4;
            scaled_alpha -= alpha_range * 4;
        }
        if scaled_alpha >= alpha_range * 2 {
            palette_step += 2;
            scaled_alpha -= alpha_range * 2;
        }
        if scaled_alpha >= alpha_range palette_step += 1;

        // the BC3 palette stores the two endpoints first, followed by the six interpolated values.
        alpha_index := (8 - palette_step) & 7;
        if alpha_index < 2 alpha_index ^= 1;
        packed_indices |= cast(u64) alpha_index << (pixel_index * 3);
    }
    write_little_endian(destination + 2, packed_indices, 6);
}

write_little_endian :: inline (destination: *u8, value: $T, byte_count: int) {
    for byte_index: 0..byte_count - 1 {
        destination[byte_index] = cast(u8) ((value >> (byte_index * 8)) & 0xff);
    }
}
