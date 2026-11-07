#pragma once
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SpkIosContext SpkIosContext;

typedef struct {
    float tc_b_matrix[9];
    float cmy_bounds[6];
    uint32_t tc_lut_side;
    uint32_t is_monochrome;
    uint32_t tc_lut_updated;
    float halation_sigma_um;
    float scatter_sigma_um;
    float scatter_amount;
    float halation_bounce_decay;
} SpkIosPass1Meta;

uint32_t spk_ios_pass2_uniforms_size(void);

SpkIosContext* spk_ios_context_create(const char* resources_dir);
void spk_ios_context_destroy(SpkIosContext* ctx);

bool spk_ios_prepare_tables(
    SpkIosContext* ctx,
    const char* film_stock,
    const char* print_stock,
    const char* input_color_space,
    int upsampling_mode,
    double print_exposure_ev,
    double m_filter_shift_cc,
    double y_filter_shift_cc,
    int bw_grade_index,
    uint32_t frame_long_edge,
    SpkIosPass1Meta* out_meta,
    uint16_t* out_tc_lut_rgba16f,
    float* out_cam16_cmax,
    void* out_pass2_uniforms
);

#ifdef __cplusplus
}
#endif
