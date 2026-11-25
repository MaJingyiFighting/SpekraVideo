#include "SpektraCoreBridge.h"

#include "blob.hpp"
#include "cam16.hpp"
#include "colour.hpp"
#include "curves.hpp"
#include "hanatos.hpp"
#include "json.hpp"
#include "numeric.hpp"
#include "params.hpp"
#include "printing.hpp"
#include "profile.hpp"
#include "setup_cache.hpp"
#include "spectral.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <fstream>
#include <limits>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

struct SpkPass2Uniforms {
    uint32_t is_positive;
    uint32_t scan_film;
    uint32_t dir_active;
    uint32_t cam16_nl;
    uint32_t cam16_nh;
    uint32_t cam16_lc_active;
    uint32_t reserved0;
    float reserved1;
    float reserved2;
    float reserved3;

    float halation_strength[3];
    float dir_dmax[3];
    float dir_matrix[9];
    float grain_lp[12];
    float grain_dmin[3];

    float print_gain[3];
    float print_offset[3];
    float print_exposure_gain[3];

    float xyz_to_rgb[9];
    float output_matrix[9];
    float cam16_m2x[9];
    float cam16_m2r[9];
    float cam16_k[22];

    float film_curve_x[256 * 3];
    float film_curve_inv[255 * 3];
    float film_curve_y[256 * 3];
    float coupler_curve_x[256 * 3];
    float coupler_curve_inv[255 * 3];
    float coupler_curve_y[256 * 3];

    float print_chd[81 * 3];
    float print_base[81];
    float print_ixs[81 * 3];
    float print_curve_x[256 * 3];
    float print_curve_inv[255 * 3];
    float print_curve_y[256 * 3];

    float scan_chd[81 * 3];
    float scan_base[81];
    float scan_ixs[81 * 3];
};

struct SpkIosContext {
    std::string resources_dir;
    spk::Blob blob;
    spk::Colour colour;
    spk::SetupCache cache;
    spk::Json neutral_filters;
    spk::Cam16Setup cam16_p3;

    std::vector<float> arctic_spectra;
    std::unordered_map<std::string, spk::Vec> arctic_lut_cache;
    std::unordered_map<std::string, std::vector<double>> polar_hull_cache;

    std::unordered_map<std::string, spk::Profile> profile_cache;
    std::string cached_base_key;
    std::string cached_tclut_key;
    spk::Params cached_params;
    const spk::Vec* cached_lut = nullptr;
    size_t cached_lut_side = 192;
    SpkIosPass1Meta cached_meta{};
    bool cmax_copied = false;
    bool ok = false;
};

namespace {

constexpr double kPi = 3.14159265358979323846;

float half_to_float(uint16_t h) {
    const uint32_t s = (h >> 15) & 1u;
    const uint32_t e = (h >> 10) & 0x1Fu;
    const uint32_t m = h & 0x3FFu;
    float v = 0.0f;
    if (e == 0) {
        v = (m == 0) ? 0.0f : float(m) * 5.9604644775390625e-08f;
    } else if (e == 31) {
        v = 0.0f;
    } else {
        v = (1.0f + float(m) / 1024.0f) * std::ldexp(1.0f, int(e) - 15);
    }
    return s ? -v : v;
}

uint16_t float_to_half(float f) {
    uint32_t x;
    std::memcpy(&x, &f, sizeof(uint32_t));
    const uint32_t sign = (x >> 16) & 0x8000u;
    const int32_t exp = int32_t((x >> 23) & 0xFFu) - 127 + 15;
    uint32_t mant = x & 0x007FFFFFu;
    if (exp <= 0) {
        if (exp < -10) return uint16_t(sign);
        mant = (mant | 0x00800000u) >> (1 - exp);
        return uint16_t(sign | ((mant + 0x00001000u) >> 13));
    } else if (exp >= 31) {
        return uint16_t(sign | 0x7BFFu);
    }
    return uint16_t(sign | (uint32_t(exp) << 10) | ((mant + 0x00001000u) >> 13));
}

void pack_tc_lut_rgba16f(uint16_t* dst, const spk::Vec& src, size_t side) {
    const size_t cells = side * side;
    const uint16_t one_h = float_to_half(1.0f);
    for (size_t i = 0; i < cells; ++i) {
        dst[4 * i + 0] = float_to_half(static_cast<float>(src[3 * i + 0]));
        dst[4 * i + 1] = float_to_half(static_cast<float>(src[3 * i + 1]));
        dst[4 * i + 2] = float_to_half(static_cast<float>(src[3 * i + 2]));
        dst[4 * i + 3] = one_h;
    }
}

bool load_arctic_binary(const std::string& path, std::vector<float>& out) {
    std::ifstream in(path, std::ios::binary);
    if (!in) return false;
    constexpr size_t kCount = 192 * 192 * 81;
    std::vector<uint16_t> raw(kCount);
    if (!in.read(reinterpret_cast<char*>(raw.data()), kCount * sizeof(uint16_t))) {
        return false;
    }
    out.resize(kCount);
    for (size_t i = 0; i < kCount; ++i) {
        out[i] = half_to_float(raw[i]);
    }
    return true;
}

double ray_poly_dist(const double origin[2], const double dir[2], const spk::Vec& poly) {
    const size_t n_edges = poly.size() / 2 - 1;
    double t_min = std::numeric_limits<double>::infinity();
    for (size_t k = 0; k < n_edges; ++k) {
        const double ax = poly[2 * k], ay = poly[2 * k + 1];
        const double ex = poly[2 * (k + 1)] - ax, ey = poly[2 * (k + 1) + 1] - ay;
        const double denom = dir[0] * ey - dir[1] * ex;
        if (std::fabs(denom) <= 1e-12) continue;
        const double ox = origin[0] - ax, oy = origin[1] - ay;
        const double t = (-ox * ey + oy * ex) / denom;
        const double s = (-ox * dir[1] + oy * dir[0]) / denom;
        if (t > 1e-9 && s >= -1e-9 && s <= 1.0 + 1e-9 && t < t_min) t_min = t;
    }
    return t_min;
}

// 预计算并缓存以 white_xy 为原点的 512 点极角内接凸包极径表 r_inscribed[512]，将 1887 万次多边形求交降为 O(1) 极角插值
const std::vector<double>& get_inscribed_polar_radii(
    SpkIosContext* ctx,
    const std::string& illum_name,
    const double white_xy[2],
    double detail
) {
    auto it = ctx->polar_hull_cache.find(illum_name);
    if (it != ctx->polar_hull_cache.end()) {
        return it->second;
    }

    spk::Vec locus;
    spk::spectral_locus_xy(ctx->colour, locus);
    constexpr int N = 512;
    std::vector<double> reach(N, 0.15);
    for (int i = 0; i < N; ++i) {
        const double theta = (2.0 * kPi * double(i)) / double(N);
        const double dir[2] = {std::cos(theta), std::sin(theta)};
        const double d = ray_poly_dist(white_xy, dir, locus);
        reach[i] = std::isfinite(d) ? d : 0.15;
    }

    constexpr int KMax = 28;
    double a_cos[KMax + 1] = {0};
    double b_sin[KMax + 1] = {0};
    for (int k = 0; k <= KMax; ++k) {
        double sc = 0.0, ss = 0.0;
        for (int n = 0; n < N; ++n) {
            const double ang = (2.0 * kPi * double(k * n)) / double(N);
            sc += reach[n] * std::cos(ang);
            ss += reach[n] * std::sin(ang);
        }
        const double atten = std::exp(-0.5 * (double(k) / detail) * (double(k) / detail));
        a_cos[k] = (sc / double(N)) * atten;
        b_sin[k] = (ss / double(N)) * atten;
    }

    std::vector<double> r_inscribed(N, 0.0);
    double inscribe_ratio = 1.0;
    for (int n = 0; n < N; ++n) {
        double v = a_cos[0];
        for (int k = 1; k <= KMax; ++k) {
            const double ang = (2.0 * kPi * double(k * n)) / double(N);
            v += 2.0 * (a_cos[k] * std::cos(ang) + b_sin[k] * std::sin(ang));
        }
        v = std::max(v, 1e-12);
        r_inscribed[n] = v;
        inscribe_ratio = std::min(inscribe_ratio, reach[n] / v);
    }
    for (int n = 0; n < N; ++n) {
        r_inscribed[n] *= inscribe_ratio;
    }

    auto inserted = ctx->polar_hull_cache.emplace(illum_name, std::move(r_inscribed));
    return inserted.first->second;
}

double bilinear_lut_sample(const spk::Vec& lut, size_t side, size_t ch, double ci, double cj) {
    ci = std::max(0.0, std::min(double(side - 1), ci));
    cj = std::max(0.0, std::min(double(side - 1), cj));
    const size_t i0 = size_t(std::floor(ci)), j0 = size_t(std::floor(cj));
    const size_t i1 = std::min(i0 + 1, side - 1), j1 = std::min(j0 + 1, side - 1);
    const double ti = ci - double(i0), tj = cj - double(j0);
    const double v00 = lut[3 * (i0 * side + j0) + ch];
    const double v01 = lut[3 * (i0 * side + j1) + ch];
    const double v10 = lut[3 * (i1 * side + j0) + ch];
    const double v11 = lut[3 * (i1 * side + j1) + ch];
    return v00 * (1.0 - ti) * (1.0 - tj) + v01 * (1.0 - ti) * tj +
           v10 * ti * (1.0 - tj) + v11 * ti * tj;
}

bool build_arctic2026_tc_lut(
    SpkIosContext* ctx,
    const spk::Profile& film,
    const spk::Vec& film_sens,
    const spk::Vec*& out_lut_ptr,
    size_t& out_side,
    std::string& err
) {
    const std::string cache_key = film.info.stock + "|" + film.info.reference_illuminant;
    auto it = ctx->arctic_lut_cache.find(cache_key);
    if (it != ctx->arctic_lut_cache.end()) {
        out_lut_ptr = &it->second;
        out_side = 192;
        return true;
    }

    constexpr size_t side = 192;
    constexpr size_t n_lambda = 81;
    spk::Vec e_ref;
    if (!spk::standard_illuminant(ctx->colour, ctx->blob, film.info.reference_illuminant, e_ref, err)) {
        return false;
    }

    double ref_xy[2];
    spk::illuminant_to_xy(ctx->colour, e_ref, ref_xy);
    double ref_tc[2];
    spk::tri2quad(ref_xy, ref_tc);
    const double b_midgray = 0.184 / std::max(ref_xy[1], 1e-6);

    // 预乘光源与胶片三层灵敏度，利用单精度 NEON 向量化在 < 1ms 内完成 36864x81 积分
    float es0[n_lambda], es1[n_lambda], es2[n_lambda];
    for (size_t l = 0; l < n_lambda; ++l) {
        const float e = static_cast<float>(e_ref[l]);
        es0[l] = e * static_cast<float>(film_sens[3 * l + 0]);
        es1[l] = e * static_cast<float>(film_sens[3 * l + 1]);
        es2[l] = e * static_cast<float>(film_sens[3 * l + 2]);
    }

    spk::Vec raw_lut(side * side * 3, 0.0);
    for (size_t cell = 0; cell < side * side; ++cell) {
        const float* sp = &ctx->arctic_spectra[cell * n_lambda];
        float a0 = 0.0f, a1 = 0.0f, a2 = 0.0f;
        for (size_t l = 0; l < n_lambda; ++l) {
            const float s = sp[l];
            a0 += s * es0[l];
            a1 += s * es1[l];
            a2 += s * es2[l];
        }
        raw_lut[3 * cell + 0] = static_cast<double>(a0);
        raw_lut[3 * cell + 1] = static_cast<double>(a1);
        raw_lut[3 * cell + 2] = static_cast<double>(a2);
    }

    double raw_neutral[3] = {1.0, 1.0, 1.0};
    spk::lut2d_cubic_host(raw_lut, side, ref_tc, raw_neutral);
    for (int c = 0; c < 3; ++c) {
        const double inv_norm = 1.0 / std::max(raw_neutral[c] * b_midgray, 1e-12);
        for (size_t cell = 0; cell < side * side; ++cell) {
            raw_lut[3 * cell + size_t(c)] *= inv_norm;
        }
    }

    const std::vector<double>& r_inscribed = get_inscribed_polar_radii(
        ctx,
        film.info.reference_illuminant,
        ref_xy,
        5.0
    );
    constexpr int N = 512;
    constexpr double kThreshold = 0.815;
    constexpr double kLimit = 1.0;
    constexpr double kPower = 1.2;
    constexpr double kScale = kLimit - kThreshold;
    constexpr double kInvTwoPi = double(N) / (2.0 * kPi);

    spk::Vec remapped(raw_lut.size(), 0.0);
    for (size_t i = 0; i < side; ++i) {
        for (size_t j = 0; j < side; ++j) {
            const double tc[2] = {double(i) / double(side - 1), double(j) / double(side - 1)};
            double xy[2];
            spk::quad2tri(tc, xy);
            const double dx = xy[0] - ref_xy[0];
            const double dy = xy[1] - ref_xy[1];
            const double r = std::hypot(dx, dy);
            double compressed[2] = {xy[0], xy[1]};
            if (r > 1e-12) {
                double ang = std::atan2(dy, dx);
                if (ang < 0.0) ang += 2.0 * kPi;
                const double f_idx = ang * kInvTwoPi;
                const int idx0 = int(f_idx) & (N - 1);
                const int idx1 = (idx0 + 1) & (N - 1);
                const double frac = f_idx - std::floor(f_idx);
                const double r_bound = std::max(r_inscribed[idx0] * (1.0 - frac) + r_inscribed[idx1] * frac, 1e-9);
                double d = r / r_bound;
                if (d > kThreshold) {
                    const double xk = (d - kThreshold) / kScale;
                    const double yk = xk / std::pow(1.0 + std::pow(xk, kPower), 1.0 / kPower);
                    d = kThreshold + kScale * yk;
                }
                const double ratio = (d * r_bound) / r;
                compressed[0] = ref_xy[0] + dx * ratio;
                compressed[1] = ref_xy[1] + dy * ratio;
            }
            double tc2[2];
            spk::tri2quad(compressed, tc2);
            const double ci = tc2[0] * double(side - 1);
            const double cj = tc2[1] * double(side - 1);
            for (int c = 0; c < 3; ++c) {
                remapped[3 * (i * side + j) + size_t(c)] =
                    bilinear_lut_sample(raw_lut, side, size_t(c), ci, cj);
            }
        }
    }

    auto inserted = ctx->arctic_lut_cache.emplace(cache_key, std::move(remapped));
    out_lut_ptr = &inserted.first->second;
    out_side = side;
    return true;
}

bool read_file_str(const std::string& path, std::string& out) {
    std::ifstream in(path, std::ios::binary);
    if (!in) return false;
    std::ostringstream ss;
    ss << in.rdbuf();
    out = ss.str();
    return true;
}

void copy_f32(float* dst, const double* src, size_t n) {
    for (size_t i = 0; i < n; ++i) {
        dst[i] = static_cast<float>(src[i]);
    }
}

void copy_vec_f32(float* dst, const spk::Vec& src, size_t max_n) {
    const size_t n = std::min(src.size(), max_n);
    for (size_t i = 0; i < n; ++i) {
        dst[i] = static_cast<float>(src[i]);
    }
}

bool get_cached_profile(SpkIosContext* ctx, const std::string& stock, spk::Profile& out, std::string& err) {
    auto it = ctx->profile_cache.find(stock);
    if (it != ctx->profile_cache.end()) {
        out = it->second;
        return true;
    }
    if (!spk::load_profile(ctx->resources_dir, stock, out, err)) {
        return false;
    }
    ctx->profile_cache.emplace(stock, out);
    return true;
}

struct MultigradePack {
    double m;
    double y;
    double exposure;
};

constexpr MultigradePack kMultigradePacks[7] = {
    {0.0,   199.0, 0.5323}, // 00
    {0.0,   137.9, 0.6642}, // 0
    {0.0,    99.8, 0.8257}, // 1
    {0.0,    68.0, 1.0000}, // 2
    {0.0,    34.1, 1.1590}, // 3
    {39.1,    0.0, 1.3340}, // 4
    {151.7,   0.0, 1.3507}, // 5
};

} // namespace

extern "C" uint32_t spk_ios_pass2_uniforms_size(void) {
    return static_cast<uint32_t>(sizeof(SpkPass2Uniforms));
}

extern "C" SpkIosContext* spk_ios_context_create(const char* resources_dir) {
    if (!resources_dir) return nullptr;
    auto* ctx = new SpkIosContext();
    ctx->resources_dir = resources_dir;
    std::string err;

    if (!ctx->blob.open(ctx->resources_dir + "/spektrafilm_constants.bin", err)) {
        delete ctx;
        return nullptr;
    }
    if (!ctx->colour.init(ctx->blob, err)) {
        delete ctx;
        return nullptr;
    }
    std::string nf_text;
    if (!read_file_str(ctx->resources_dir + "/neutral_print_filters.json", nf_text) ||
        !spk::Json::parse(nf_text, ctx->neutral_filters, err)) {
        delete ctx;
        return nullptr;
    }
    const spk::Cam16Setup* cached_cam16 = nullptr;
    if (!ctx->cache.cam16(ctx->colour, "Display P3", cached_cam16, err) || !cached_cam16) {
        delete ctx;
        return nullptr;
    }
    ctx->cam16_p3 = *cached_cam16;
    load_arctic_binary(ctx->resources_dir + "/arctic2026beta04.bin", ctx->arctic_spectra);
    ctx->ok = true;
    return ctx;
}

extern "C" void spk_ios_context_destroy(SpkIosContext* ctx) {
    delete ctx;
}

extern "C" bool spk_ios_prepare_tables(
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
) {
    if (!ctx || !ctx->ok || !film_stock || !print_stock || !input_color_space ||
        !out_meta || !out_tc_lut_rgba16f || !out_cam16_cmax || !out_pass2_uniforms) {
        return false;
    }
    auto* p2 = static_cast<SpkPass2Uniforms*>(out_pass2_uniforms);
    std::string err;

    spk::Profile probe_film;
    if (!get_cached_profile(ctx, film_stock, probe_film, err)) {
        return false;
    }

    std::string effective_print = print_stock;
    if (probe_film.info.channel_model == "bw") {
        effective_print = "ilford_multigrade_iv_rc";
    } else if (effective_print == "ilford_multigrade_iv_rc") {
        effective_print = "fujifilm_crystal_archive_typeii";
    }

    const uint32_t long_edge = std::max(frame_long_edge, 1920u);
    // base_key 不纳入 long_edge，切换 1080p/4K 时无需重建光谱或相纸查找表，仅更新 grain_lp 粒子数
    const std::string base_key = std::string(film_stock) + "|" + effective_print + "|" +
                                 input_color_space + "|" + std::to_string(upsampling_mode);

    if (!ctx->cmax_copied) {
        copy_vec_f32(out_cam16_cmax, ctx->cam16_p3.c_max_table, 128 * 360);
        ctx->cmax_copied = true;
    }

    if (base_key == ctx->cached_base_key && ctx->cached_lut != nullptr) {
        spk::Params& params = ctx->cached_params;
        double base_print_exposure = 1.0;
        if (params.print.info.stock == "ilford_multigrade_iv_rc") {
            const int g = std::max(0, std::min(bw_grade_index, 6));
            params.enlarger.c_filter_neutral = 0.0;
            params.enlarger.m_filter_neutral = kMultigradePacks[g].m;
            params.enlarger.y_filter_neutral = kMultigradePacks[g].y;
            base_print_exposure = kMultigradePacks[g].exposure;
        }
        params.enlarger.filter_shift_scale = 1.0;
        params.enlarger.m_filter_shift = m_filter_shift_cc;
        params.enlarger.y_filter_shift = y_filter_shift_cc;
        params.enlarger.print_exposure = base_print_exposure * std::pow(2.0, print_exposure_ev);

        const double px_um = (params.camera.film_format_mm * 1000.0) / double(long_edge);
        const spk::GrainParams& gr = params.film_render.grain;
        for (int ch = 0; ch < 3; ++ch) {
            const double n_particles = (px_um * px_um) / (gr.particle_area_um2 * gr.particle_scale[ch]);
            p2->grain_lp[4 * ch + 2] = static_cast<float>(n_particles);
        }

        if (!params.io.scan_film) {
            spk::PrintConstants pc;
            if (!spk::print_constants(ctx->colour, ctx->blob, params, *ctx->cached_lut, ctx->cached_lut_side, pc, err)) {
                return false;
            }
            copy_vec_f32(p2->print_chd, pc.spectral.channel_density, 81 * 3);
            copy_vec_f32(p2->print_base, pc.spectral.base_density, 81);
            copy_vec_f32(p2->print_ixs, pc.spectral.illum_x_sens, 81 * 3);
            copy_f32(p2->print_gain, pc.gain, 3);
            copy_f32(p2->print_offset, pc.offset, 3);
            for (int c = 0; c < 3; ++c) {
                p2->print_exposure_gain[c] = static_cast<float>(params.enlarger.print_exposure);
            }
        }
        *out_meta = ctx->cached_meta;
        out_meta->tc_lut_updated = 0u;
        return true;
    }

    std::memset(out_meta, 0, sizeof(SpkIosPass1Meta));
    std::memset(p2, 0, sizeof(SpkPass2Uniforms));

    spk::Params params;
    params.film = probe_film;
    if (!get_cached_profile(ctx, effective_print, params.print, err)) {
        return false;
    }
    const std::string di_paper = params.film.info.target_print.empty() ? effective_print
                                                                       : params.film.info.target_print;
    if (!get_cached_profile(ctx, di_paper, params.di_paper, err)) {
        return false;
    }
    params.film_stock = params.film.info.stock.empty() ? film_stock : params.film.info.stock;
    params.print_stock = params.print.info.stock.empty() ? effective_print : params.print.info.stock;
    if (!spk::digest(params, ctx->neutral_filters, err)) {
        return false;
    }

    params.io.input_gamut_compress.knee[0] = 0.815;
    params.io.input_gamut_compress.knee[1] = 1.0;
    params.io.input_gamut_compress.knee[2] = 1.2;
    params.io.output_gamut_compress.knee[0] = 0.95;
    params.io.output_gamut_compress.knee[1] = 1.0;
    params.io.output_gamut_compress.knee[2] = 1.6;
    params.io.output_gamut_compress.lightness_compression[0] = 0.95;
    params.io.output_gamut_compress.lightness_compression[1] = 1.0;
    params.io.output_gamut_compress.lightness_compression[2] = 1.6;

    params.io.input_color_space = input_color_space;
    params.io.output_color_space = "Display P3";
    params.camera.exposure_compensation_ev = 0.0;
    params.enlarger.print_exposure_compensation = false;
    params.enlarger.normalize_print_exposure = true;
    params.io.scan_film = params.film.info.is_positive();

    double base_print_exposure = 1.0;
    if (params.print.info.stock == "ilford_multigrade_iv_rc") {
        const int g = std::max(0, std::min(bw_grade_index, 6));
        params.enlarger.c_filter_neutral = 0.0;
        params.enlarger.m_filter_neutral = kMultigradePacks[g].m;
        params.enlarger.y_filter_neutral = kMultigradePacks[g].y;
        base_print_exposure = kMultigradePacks[g].exposure;
    }

    params.enlarger.filter_shift_scale = 1.0;
    params.enlarger.m_filter_shift = m_filter_shift_cc;
    params.enlarger.y_filter_shift = y_filter_shift_cc;
    params.enlarger.print_exposure = base_print_exposure * std::pow(2.0, print_exposure_ev);

    p2->is_positive = params.film.info.is_positive() ? 1u : 0u;
    p2->scan_film = params.io.scan_film ? 1u : 0u;
    out_meta->is_monochrome = (params.film.info.channel_model == "bw") ? 1u : 0u;

    spk::Vec film_sens;
    if (!spk::film_sensitivity(ctx->colour, ctx->blob, params.film, params.camera, film_sens, err)) {
        return false;
    }
    const spk::Vec* lut = nullptr;
    size_t side = 0;
    if (upsampling_mode == 0 && !ctx->arctic_spectra.empty()) {
        if (!build_arctic2026_tc_lut(ctx, params.film, film_sens, lut, side, err) || !lut) {
            return false;
        }
    } else {
        if (!ctx->cache.tc_lut(ctx->colour, ctx->blob, params.film, params.settings,
                               params.io.input_gamut_compress, film_sens, lut, side, err) || !lut) {
            return false;
        }
    }
    out_meta->tc_lut_side = static_cast<uint32_t>(side);
    const std::string tclut_key = std::string(film_stock) + "|" + std::to_string(upsampling_mode);
    if (tclut_key != ctx->cached_tclut_key) {
        pack_tc_lut_rgba16f(out_tc_lut_rgba16f, *lut, side);
        ctx->cached_tclut_key = tclut_key;
        out_meta->tc_lut_updated = 1u;
    } else {
        out_meta->tc_lut_updated = 0u;
    }

    spk::Mat3 tc_b;
    if (!spk::tc_b_matrix(ctx->colour, ctx->blob, params.io.input_color_space,
                          params.film.info.reference_illuminant, tc_b, err)) {
        return false;
    }
    double row9[9];
    tc_b.to_row_major(row9);
    copy_f32(out_meta->tc_b_matrix, row9, 9);

    const double gamma[3] = {
        params.film_render.density_curve_gamma,
        params.film_render.density_curve_gamma,
        params.film_render.density_curve_gamma
    };
    {
        spk::InterpTables t;
        spk::build_interp_tables(params.film.data.log_exposure, gamma, params.film.normalized_curves, t);
        copy_vec_f32(p2->film_curve_x, t.x, 256 * 3);
        copy_vec_f32(p2->film_curve_inv, t.inv, 255 * 3);
        copy_vec_f32(p2->film_curve_y, t.y, 256 * 3);
    }

    p2->dir_active = params.film_render.dir_couplers.active ? 1u : 0u;
    if (params.film_render.dir_couplers.active) {
        double dmat[9];
        spk::dir_couplers_matrix(params.film_render.dir_couplers, dmat);
        copy_f32(p2->dir_matrix, dmat, 9);
        copy_f32(p2->dir_dmax, params.film.density_max, 3);

        spk::Vec curves0;
        spk::density_curves_before_dir_couplers(
            params.film.normalized_curves,
            params.film.data.log_exposure,
            dmat,
            params.film.info.is_positive(),
            curves0
        );
        spk::InterpTables t0;
        spk::build_interp_tables(params.film.data.log_exposure, gamma, curves0, t0);
        copy_vec_f32(p2->coupler_curve_x, t0.x, 256 * 3);
        copy_vec_f32(p2->coupler_curve_inv, t0.inv, 255 * 3);
        copy_vec_f32(p2->coupler_curve_y, t0.y, 256 * 3);
    }

    for (int c = 0; c < 3; ++c) {
        float max_y = 1.0f;
        for (int i = 0; i < 256; ++i) {
            max_y = std::max(max_y, p2->film_curve_y[i * 3 + c]);
            if (p2->dir_active != 0u) {
                max_y = std::max(max_y, p2->coupler_curve_y[i * 3 + c]);
            }
        }
        const float gdmin = static_cast<float>(params.film_render.grain.density_min[c]);
        out_meta->cmy_bounds[c]     = -gdmin - 0.05f;
        out_meta->cmy_bounds[3 + c] = max_y + gdmin + 0.15f;
    }

    for (int c = 0; c < 3; ++c) {
        p2->halation_strength[c] = static_cast<float>(params.film_render.halation.halation_strength[c]);
    }
    out_meta->halation_sigma_um = static_cast<float>(
        params.film_render.halation.back_reflection
            ? params.film_render.halation.base_thickness_um
            : params.film_render.halation.halation_first_sigma_um[0]
    );
    out_meta->scatter_sigma_um = static_cast<float>(params.film_render.halation.scatter_core_um[0]);
    out_meta->scatter_amount = static_cast<float>(params.film_render.halation.scatter_amount);
    out_meta->halation_bounce_decay = static_cast<float>(params.film_render.halation.halation_bounce_decay);

    const double px_um = (params.camera.film_format_mm * 1000.0) / double(long_edge);
    const spk::GrainParams& g = params.film_render.grain;
    for (int ch = 0; ch < 3; ++ch) {
        const double dmax = params.film.density_max[ch] + g.density_min[ch];
        const double n_particles = (px_um * px_um) / (g.particle_area_um2 * g.particle_scale[ch]);
        p2->grain_lp[4 * ch + 0] = static_cast<float>(g.density_min[ch]);
        p2->grain_lp[4 * ch + 1] = static_cast<float>(dmax);
        p2->grain_lp[4 * ch + 2] = static_cast<float>(n_particles);
        p2->grain_lp[4 * ch + 3] = static_cast<float>(g.uniformity[ch]);
        p2->grain_dmin[ch] = static_cast<float>(g.density_min[ch]);
    }

    if (!params.io.scan_film) {
        spk::PrintConstants pc;
        if (!spk::print_constants(ctx->colour, ctx->blob, params, *lut, side, pc, err)) {
            return false;
        }
        copy_vec_f32(p2->print_chd, pc.spectral.channel_density, 81 * 3);
        copy_vec_f32(p2->print_base, pc.spectral.base_density, 81);
        copy_vec_f32(p2->print_ixs, pc.spectral.illum_x_sens, 81 * 3);
        copy_f32(p2->print_gain, pc.gain, 3);
        copy_f32(p2->print_offset, pc.offset, 3);
        for (int c = 0; c < 3; ++c) {
            p2->print_exposure_gain[c] = static_cast<float>(params.enlarger.print_exposure);
        }

        spk::Vec morphed;
        if (!spk::print_curves_morph(
                params.print.data.log_exposure,
                params.print.data.model,
                params.print_render.density_curves_morph,
                params.print.info.is_positive(),
                morphed,
                err)) {
            return false;
        }
        const double one[3] = {1.0, 1.0, 1.0};
        spk::InterpTables pt;
        spk::build_interp_tables(params.print.data.log_exposure, one, morphed, pt);
        copy_vec_f32(p2->print_curve_x, pt.x, 256 * 3);
        copy_vec_f32(p2->print_curve_inv, pt.inv, 255 * 3);
        copy_vec_f32(p2->print_curve_y, pt.y, 256 * 3);
    }

    {
        const spk::Profile& scanned = params.io.scan_film ? params.film : params.print;
        const std::string& illum_name = scanned.info.viewing_illuminant;
        spk::Vec illum;
        if (!spk::standard_illuminant(ctx->colour, ctx->blob, illum_name, illum, err)) {
            return false;
        }
        const spk::Vec& cmfs = ctx->colour.cmfs_1931_2deg();
        double norm = 0.0;
        for (size_t i = 0; i < illum.size(); ++i) {
            norm += illum[i] * cmfs[3 * i + 1];
        }
        spk::SpectralConstants sc;
        spk::prepare_spectral_constants(
            scanned.data.channel_density,
            scanned.data.base_density,
            illum,
            cmfs,
            norm,
            sc
        );
        copy_vec_f32(p2->scan_chd, sc.channel_density, 81 * 3);
        copy_vec_f32(p2->scan_base, sc.base_density, 81);
        copy_vec_f32(p2->scan_ixs, sc.illum_x_sens, 81 * 3);

        double illum_xyz[3] = {0.0, 0.0, 0.0};
        for (size_t i = 0; i < illum.size(); ++i) {
            for (int c = 0; c < 3; ++c) {
                illum_xyz[c] += illum[i] * cmfs[3 * i + c];
            }
        }
        for (int c = 0; c < 3; ++c) illum_xyz[c] /= norm;
        double illum_xy[2];
        spk::Colour::XYZ_to_xy(illum_xyz, illum_xy);

        spk::Mat3 m_xyz_rgb;
        if (!ctx->colour.matrix_XYZ_to_RGB(params.io.output_color_space, illum_xy, "CAT02", m_xyz_rgb, err)) {
            return false;
        }
        m_xyz_rgb.transposed().to_row_major(row9);
        copy_f32(p2->xyz_to_rgb, row9, 9);

        spk::Mat3 m_out;
        if (!ctx->colour.matrix_RGB_to_RGB(params.io.output_color_space, params.io.output_color_space, "", m_out, err)) {
            return false;
        }
        m_out.transposed().to_row_major(row9);
        copy_f32(p2->output_matrix, row9, 9);
    }

    {
        const spk::Cam16Setup& c16 = ctx->cam16_p3;
        const spk::GamutCompressSpec& og = params.io.output_gamut_compress;
        c16.m_to_xyz.to_row_major(row9);
        copy_f32(p2->cam16_m2x, row9, 9);
        c16.m_to_rgb.to_row_major(row9);
        copy_f32(p2->cam16_m2r, row9, 9);

        const double consts[22] = {
            c16.F_L, c16.N_bb, c16.N_cb, c16.n, c16.z, c16.A_w, c16.c, c16.N_c,
            c16.l_grid.front(), c16.l_grid.back(),
            c16.h_grid.front(), c16.h_grid[1] - c16.h_grid[0],
            og.knee[0], og.knee[1], og.knee[2],
            og.lightness_compression_active ? og.lightness_compression[0] : 0.0,
            og.lightness_compression_active ? og.lightness_compression[1] : 1.0,
            og.lightness_compression_active ? og.lightness_compression[2] : 1.0,
            c16.white_Jp, c16.D_rgb[0], c16.D_rgb[1], c16.D_rgb[2],
        };
        copy_f32(p2->cam16_k, consts, 22);
        p2->cam16_nl = static_cast<uint32_t>(c16.l_grid.size());
        p2->cam16_nh = static_cast<uint32_t>(c16.h_grid.size());
        p2->cam16_lc_active = og.lightness_compression_active ? 1u : 0u;
    }

    ctx->cached_base_key = base_key;
    ctx->cached_params = params;
    ctx->cached_lut = lut;
    ctx->cached_lut_side = side;
    ctx->cached_meta = *out_meta;

    return true;
}
