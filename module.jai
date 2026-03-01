#import "tbx/section_logger";

/*

Why is this thing not called a texture atlas? It could have been, but then people already make models that use textures that are texture atlases.

That would mean our texture atlas can contain texture atlases, so then whenever we talk about texture atlases we would have to disambiguate if we are 
talking about this system or the texture atlases that live inside it. 

Thus when dealing with the textures that this system produces they are called "packed textures", and so we talk about packing instead of atlases.

This choice allows us to instantly disambiguate between atlases and packed textures, and we can now talk about texture atlases that are in packed textures easily.

*/

#load "pack_textures.jai";
#load "split_packer.jai";
#load "packed_texture_rendering.jai";
