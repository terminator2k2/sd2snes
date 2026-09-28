#!/bin/bash
# Build the Opus decoder for the Xeno Crisis decode service (xc_audio.c) on the mk3 MCU (STM32F401).
#   xc_opus/build.sh <opus-1.3.1 source dir>      ->  xc_opus/libopus_xc.a, xc_opus/include/
#
# The decoder must produce exactly what the cartridge's RP2040 firmware produces (libopus 1.3.1, fixed point):
#   - FIXED_POINT, DISABLE_FLOAT_API, no float code;
#   - CELT: the portable C macros, with m4_exact.patch (M4_EXACT: 64-bit MULT16_32_Q16/P16/Q15, which give the
#     same results as the 16x16 split). Do NOT enable the CELT ARMv5E macros: their MULT16_32_Q15 drops a bit.
#   - SILK: the ARMv5E inline-assembly macros (exact).
# MCU time for the game's music (instruction-level Cortex-M4 model, before flash wait states): about 30 M cycles/s
# (36% of 84 MHz) as built here: -Os, except the hot CELT synthesis files at -O2 (FFT, MDCT, comb filter,
# deemphasis: -10% time for +1.8 KB), small-footprint cwrs.c. All -O2 with the PVQ table would be 26 M but does
# not fit.
set -e
S=$(cd "$1" && pwd)
D=$(cd "$(dirname "$0")" && pwd)
B=$(mktemp -d)
trap 'rm -rf "$B"' EXIT
cp -r "$S"/celt "$S"/silk "$S"/src "$S"/include "$B"/
patch -s -d "$B" -p1 < "$D"/m4_exact.patch
CC=${CC:-arm-none-eabi-gcc}
AR=${AR:-arm-none-eabi-ar}
# -Os by default: the firmware with the embedded mini bitstream (fpga_mini.bi3, 56,939 bytes) does not fit the
# 212,480-byte application flash with -O2 (about 20 KB over).
OPT=${OPT:--Os}
OPT_HOT=${OPT_HOT:--O2}
HOT="kiss_fft mdct celt celt_decoder"
CF="-mthumb -mcpu=cortex-m4 -mfloat-abi=hard -ffunction-sections -fdata-sections -Wall -Wno-unused
    -DOPUS_BUILD -DFIXED_POINT -DDISABLE_FLOAT_API -DVAR_ARRAYS -DHAVE_LRINT -DHAVE_LRINTF -DM4_EXACT
    -I$B -I$B/include -I$B/celt -I$B/silk -I$B/silk/fixed"
# cwrs.c only: compute the PVQ codeword counts instead of the 5 KB CELT_PVQ_U_DATA table (exact integer code;
# bit-exact, checked with the m4bench checksum). The rest of SMALL_FOOTPRINT is left off.
CWRS="-DSMALL_FOOTPRINT"
SILK="-DOPUS_ARM_INLINE_ASM -DOPUS_ARM_INLINE_EDSP -DOPUS_ARM_INLINE_MEDIA"
CELT_SRC="bands celt celt_decoder celt_lpc cwrs entcode entdec entenc kiss_fft laplace mathops mdct modes pitch quant_bands rate vq"
SILK_SRC="CNG LPC_analysis_filter LPC_fit LPC_inv_pred_gain NLSF2A NLSF_decode NLSF_stabilize NLSF_unpack PLC bwexpander
    bwexpander_32 code_signs dec_API decode_core decode_frame decode_indices decode_parameters decode_pitch decode_pulses
    decoder_set_fs gain_quant init_decoder lin2log log2lin pitch_est_tables resampler resampler_private_AR2
    resampler_private_IIR_FIR resampler_private_down_FIR resampler_private_up2_HQ resampler_rom shell_coder sort
    stereo_MS_to_LR stereo_decode_pred sum_sqr_shift table_LSF_cos tables_LTP tables_NLSF_CB_NB_MB tables_NLSF_CB_WB
    tables_gain tables_other tables_pitch_lag tables_pulses_per_block"
SRC_SRC="opus opus_decoder"
objs=""
for f in $CELT_SRC; do
  x=""; [ $f = cwrs ] && x="$CWRS"
  o=$OPT; case " $HOT " in *" $f "*) o=$OPT_HOT;; esac
  $CC $CF $o $x -c $B/celt/$f.c -o $B/celt_$f.o; objs="$objs $B/celt_$f.o"
done
for f in $SILK_SRC; do $CC $CF $OPT $SILK -c $B/silk/$f.c -o $B/silk_$f.o; objs="$objs $B/silk_$f.o"; done
for f in $SRC_SRC; do $CC $CF $OPT -c $B/src/$f.c -o $B/src_$f.o; objs="$objs $B/src_$f.o"; done
rm -f "$D"/libopus_xc.a
$AR rcs "$D"/libopus_xc.a $objs
rm -rf "$D"/include && cp -r "$B"/include "$D"/include
echo "$D/libopus_xc.a: $(echo $objs | wc -w) objects"
