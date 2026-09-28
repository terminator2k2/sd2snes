/* dec2 <dump> <out.raw> <stream> [<stream> ...]: decode the streams one after the other with ONE decoder (as the
   game's mixer does: intro -> loop -> loop ...), 48 kHz s16 stereo; prints the samples per stream */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include "opus.h"
static uint8_t* f;
static uint32_t r32(uint32_t a) { a -= 0x10000000; return f[a] | f[a+1] << 8 | f[a+2] << 16 | (uint32_t)f[a+3] << 24; }
static uint32_t be32(uint32_t a) { a -= 0x10000000; return (uint32_t)f[a] << 24 | f[a+1] << 16 | f[a+2] << 8 | f[a+3]; }
int main(int c, char** v) {
  FILE* d = fopen(v[1], "rb"); f = malloc(16 << 20); if(fread(f, 1, 16 << 20, d) != 16 << 20) return 1; fclose(d);
  int err; OpusDecoder* dec = opus_decoder_create(48000, 2, &err);
  FILE* o = fopen(v[2], "wb"); int16_t pcm[5760 * 2];
  for(int a = 3; a < c; a++) {
    int n = atoi(v[a]); uint32_t base = r32(0x1071BD70 + 4 * n), len = r32(0x1071BDE0 + 4 * n); long total = 0; int bad = 0;
    for(uint32_t off = 0; off + 8 <= len;) {
      uint32_t l = be32(base + off); off += 8; if(l > 1500) break;
      int s = l ? opus_decode(dec, f + base + off - 0x10000000, l, pcm, 5760, 0) : opus_decode(dec, NULL, 0, pcm, 960, 0);
      off += l;
      if(s < 0) { bad++; continue; }
      fwrite(pcm, 4, s, o); total += s;
    }
    printf("%d %ld %d\n", n, total, bad);
  }
  fclose(o); return 0;
}
