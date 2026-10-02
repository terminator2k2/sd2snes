#!/bin/bash
# Build the Opus decoder for the Xeno Crisis decode service (xc_audio.c) on the mk3 MCU (STM32F401).
#   xc_opus/build.sh <opus-1.3.1 source dir>      ->  xc_opus/libopus_xc.a, xc_opus/include/
#
# The decoder must produce exactly what the cartridge's RP2040 firmware produces (libopus 1.3.1, fixed point):
#   - FIXED_POINT, DISABLE_FLOAT_API, no float code;
#   - CELT: the portable C macros, with m4_exact.patch (M4_EXACT: 64-bit MULT16_32_Q16/P16/Q15, which give the
#     same results as the 16x16 split). Do NOT enable the CELT ARMv5E macros: their MULT16_32_Q15 drops a bit.
#   - SILK: the ARMv5E inline-assembly macros (exact).
#   - SILK: without the downsampling resampler (xc_nodownsample.patch, XC_NO_DOWNSAMPLE): the decoder runs at 24 kHz,
#     above every SILK internal rate, so it only ever upsamples; saves about 1.3 KB of flash.
#   - CELT: without the encoder's calls in the shared band code (xc_decoder_only.patch, XC_DECODER_ONLY); saves
#     about 1.3 KB.
#   - xc_trim.patch: SILK wideband only (XC_SILK_WB_ONLY: the game's hybrid packets never use SILK narrowband or
#     mediumband), no FFT for 10 ms frames (XC_FFT_NO_SHIFT1: the game only has 20 ms frames: MDCT shifts 0
#     and 3, and 2 for the 5 ms transition frames), and only the ctl requests in use (XC_CTL_MIN).
#   The game's 26 music streams (66,990 packets) are all CELT or hybrid super-wideband, 20 ms, stereo, one frame
#   per packet.
#   Every change here is checked bit-exact: all 26 music streams of the game decoded with and without it (every
#   sample and final range), and the Cortex-M4 model checksum 0xdb88f8e0.
# MCU time for the game's music (instruction-level Cortex-M4 model, before flash wait states): about 33 M cycles/s
# (40% of 84 MHz, about 7.8 ms per 20 ms packet) as built here: -Os throughout, unity build, small-footprint
# cwrs.c. OPT_HOT=-O2 builds the hot CELT synthesis files (FFT, MDCT, comb filter, deemphasis) at -O2 instead:
# -10% time for +1.8 KB of flash.
set -e
S=$(cd "$1" && pwd)
D=$(cd "$(dirname "$0")" && pwd)
B=$(mktemp -d)
trap 'rm -rf "$B"' EXIT
cp -r "$S"/celt "$S"/silk "$S"/src "$S"/include "$B"/
patch -s -d "$B" -p1 < "$D"/m4_exact.patch
patch -s -d "$B" -p1 < "$D"/xc_nodownsample.patch
patch -s -d "$B" -p1 < "$D"/xc_decoder_only.patch
patch -s -d "$B" -p1 < "$D"/xc_trim.patch
CC=${CC:-arm-none-eabi-gcc}
AR=${AR:-arm-none-eabi-ar}
# -Os by default: the firmware with the embedded mini bitstream (fpga_mini.bi3, 56,939 bytes) does not fit the
# 212,480-byte application flash with -O2 (about 20 KB over).
OPT=${OPT:--Os}
OPT_HOT=${OPT_HOT:--Os}
HOT="kiss_fft mdct celt celt_decoder"
CF="-mthumb -mcpu=cortex-m4 -mfloat-abi=hard -ffunction-sections -fdata-sections -Wall -Wno-unused
    -DOPUS_BUILD -DFIXED_POINT -DDISABLE_FLOAT_API -DVAR_ARRAYS -DHAVE_LRINT -DHAVE_LRINTF -DM4_EXACT -DXC_NO_DOWNSAMPLE -DXC_DECODER_ONLY -DXC_SILK_WB_ONLY -DXC_FFT_NO_SHIFT1 -DXC_CTL_MIN
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
# UNITY=1 (default): each group of files is compiled as one translation unit, so the compiler can inline across
# files and drop what is never called. The groups keep the per-file settings apart: the hot CELT files (-O2), the
# other CELT files (-Os), cwrs.c (SMALL_FOOTPRINT), SILK (the ARMv5E inline-assembly macros), src/.
UNITY=${UNITY:-1}
unit() {   # unit <name> <dir> <flags> <files...>
  local n=$1 d=$2 f=$3; shift 3
  if [ "$UNITY" = 1 ]; then
    # opus_custom.h declares the CELT decoder functions differently unless CELT_DECODER_C is defined (as in
    # celt_decoder.c); it is read once per unit, so define it for the whole unit
    echo "#define CELT_DECODER_C" > $B/u_$n.c
    for x in "$@"; do echo "#include \"$d/$x.c\"" >> $B/u_$n.c; done
    $CC $CF $f -c $B/u_$n.c -o $B/u_$n.o; objs="$objs $B/u_$n.o"
  else
    for x in "$@"; do $CC $CF $f -c $B/$d/$x.c -o $B/${d}_$x.o; objs="$objs $B/${d}_$x.o"; done
  fi
}
hot=""; cold=""
for f in $CELT_SRC; do
  case " $HOT " in *" $f "*) hot="$hot $f";; *) [ $f != cwrs ] && cold="$cold $f";; esac
done
unit celt_hot celt "$OPT_HOT" $hot
# bands.c last: its XC_DECODER_ONLY macros (xc_decoder_only.patch) replace encoder functions that vq.c defines
cold="$(echo $cold | sed 's/\<bands\>//') bands"
unit celt_cold celt "$OPT" $cold
unit celt_cwrs celt "$OPT $CWRS" cwrs
unit silk silk "$OPT $SILK" $SILK_SRC
unit src src "$OPT" $SRC_SRC
rm -f "$D"/libopus_xc.a
$AR rcs "$D"/libopus_xc.a $objs
rm -rf "$D"/include && cp -r "$B"/include "$D"/include
echo "$D/libopus_xc.a: $(echo $objs | wc -w) objects"
