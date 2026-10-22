#include "NativeShims.h"

#include <vpx/vp8cx.h>
#include <vpx/vp8dx.h>

int macease_opus_set_bitrate(OpusEncoder *encoder, opus_int32 bitrate) {
    return opus_encoder_ctl(encoder, OPUS_SET_BITRATE(bitrate));
}

int macease_opus_set_complexity(OpusEncoder *encoder, opus_int32 complexity) {
    return opus_encoder_ctl(encoder, OPUS_SET_COMPLEXITY(complexity));
}

int macease_opus_get_lookahead(OpusEncoder *encoder, opus_int32 *samples) {
    return opus_encoder_ctl(encoder, OPUS_GET_LOOKAHEAD(samples));
}

static vpx_codec_iface_t *encoder_interface(int vp9) {
    return vp9 ? vpx_codec_vp9_cx() : vpx_codec_vp8_cx();
}

vpx_codec_err_t macease_vpx_default_config(vpx_codec_enc_cfg_t *config, int vp9) {
    return vpx_codec_enc_config_default(encoder_interface(vp9), config, 0);
}

vpx_codec_err_t macease_vpx_encoder_init(vpx_codec_ctx_t *context, const vpx_codec_enc_cfg_t *config, int vp9) {
    return vpx_codec_enc_init(context, encoder_interface(vp9), config, 0);
}

vpx_codec_err_t macease_vpx_decoder_init(vpx_codec_ctx_t *context, int vp9, unsigned int threads) {
    vpx_codec_dec_cfg_t config = {threads, 0, 0};
    return vpx_codec_dec_init(context, vp9 ? vpx_codec_vp9_dx() : vpx_codec_vp8_dx(), &config, 0);
}

vpx_codec_err_t macease_vpx_control(vpx_codec_ctx_t *context, int control, int value) {
    return vpx_codec_control_(context, control, value);
}

int macease_vpx_control_cpu_used(void) { return VP8E_SET_CPUUSED; }
int macease_vpx_control_cq_level(void) { return VP8E_SET_CQ_LEVEL; }
int macease_vpx_control_row_mt(void) { return VP9E_SET_ROW_MT; }
int macease_vpx_control_tile_columns(void) { return VP9E_SET_TILE_COLUMNS; }
