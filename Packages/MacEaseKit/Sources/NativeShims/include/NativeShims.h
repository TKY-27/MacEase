// Typed wrappers for variadic C APIs.
#ifndef NATIVE_SHIMS_H
#define NATIVE_SHIMS_H

#include <opus/opus.h>
#include <vpx/vpx_decoder.h>
#include <vpx/vpx_encoder.h>

int macease_opus_set_bitrate(OpusEncoder *encoder, opus_int32 bitrate);
int macease_opus_set_complexity(OpusEncoder *encoder, opus_int32 complexity);
int macease_opus_get_lookahead(OpusEncoder *encoder, opus_int32 *samples);

vpx_codec_err_t macease_vpx_encoder_init(vpx_codec_ctx_t *context, const vpx_codec_enc_cfg_t *config, int vp9);
vpx_codec_err_t macease_vpx_decoder_init(vpx_codec_ctx_t *context, int vp9, unsigned int threads);
vpx_codec_err_t macease_vpx_control(vpx_codec_ctx_t *context, int control, int value);
vpx_codec_err_t macease_vpx_default_config(vpx_codec_enc_cfg_t *config, int vp9);

int macease_vpx_control_cpu_used(void);
int macease_vpx_control_cq_level(void);
int macease_vpx_control_row_mt(void);
int macease_vpx_control_tile_columns(void);

#endif
