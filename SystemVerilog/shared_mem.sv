/**

- instrctions
- frame buffer A - input, to be computed
- frame buffer B - results, to be outputed
- MMIO - (tid / width / etc)

    e.g.
    apply a foo filter on an image

    instruction - stores instr of a function named "foo"
    fb_A - source image, indexed by position of pixel, each entry is rgb val of corresponding pixel
    fb_B - result image with the filter applied, same structure as fb_A
    
    fb_B[pixel_idx] = filter(fb_A[pixel_idx])

    ** overwrite in place - one large fram buffer instead of separating A / B
    - works if output format / size identical to input

**/
