# mkgamepack.py <xenocrisis_rp2040.bin> <outdir>: a full MSU-1 pack (all 26 tracks) from the game's own music, the Opus
# streams in the RP2040 flash dump (see ../MSU1_PACK.md for the track list). Needs python3 with numpy and scipy, ffmpeg
# (loudness), and xc_opusdec next to this script:
#   cc -O2 -I<opus-1.3.1>/include xc_opusdec.c <libopus.a> -lm -o xc_opusdec
# Writes "Xeno Crisis.msu" (empty) and "Xeno Crisis-<n>.pcm"; rename them to match your ROM file.
# Decoded at 48 kHz with one continuous decoder per play sequence (as the game), resampled to 44.1 kHz (exact:
# 960 -> 882 samples per packet), one common gain for all tracks (the game's balance), TPDF dither.
import sys, os, struct, subprocess, numpy as np
from scipy.signal import resample_poly
import tempfile
DEC = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'xc_opusdec')
SEQ = os.path.join(tempfile.gettempdir(), 'xc_seq.raw'); TMPF = os.path.join(tempfile.gettempdir(), 'xc_t.f32')
dump, out = sys.argv[1], sys.argv[2]
once  = {1, 2, 24, 25}                                   # played once (2: once or looped: a clean restart at 0)
pairs = {4: 5, 8: 9, 10: 11, 12: 13, 14: 15, 18: 19}     # intro -> loop
loops = {3, 6, 7, 16, 17, 20, 21, 22, 23, 26}            # the whole track loops onto itself
X = 2205                                                 # loop point 50 ms in (past the decoder's start-up)
def decode(streams):                                     # MSU track numbers -> 44.1 kHz float, samples per stream
    r = subprocess.run([DEC, dump, SEQ] + [str(n - 1) for n in streams], capture_output=True, text=True)
    lens = [int(l.split()[1]) for l in r.stdout.split('\n') if l.strip()]
    assert all(int(l.split()[2]) == 0 for l in r.stdout.split('\n') if l.strip()), r.stdout
    x = np.fromfile(SEQ, dtype='<i2').reshape(-1, 2).astype(np.float64) / 32768
    y = resample_poly(x, 147, 160, axis=0)
    return y, [l * 147 // 160 for l in lens]
files = {}                                               # track -> (samples, loop point)
for n in sorted(once):
    y, L = decode([n]); files[n] = (y[:L[0]], 0)
for n in sorted(loops):
    y, L = decode([n, n, n]); files[n] = (y[:L[0] + X], X)
for i, l in pairs.items():
    y, L = decode([i, l, l, l]); files[i] = (y[:L[0]], 0); files[l] = (y[L[0]:L[0] + L[1] + X], X)
def lufs(v):
    v.astype(np.float32).tofile(TMPF)
    o = subprocess.run(['ffmpeg', '-hide_banner', '-f', 'f32le', '-ar', '44100', '-ac', '2', '-i', TMPF, '-af', 'ebur128=framelog=quiet', '-f', 'null', '-'], capture_output=True, text=True).stderr
    return float([l for l in o.split('\n') if 'I:' in l][-1].split()[1])
loud = {n: lufs(v) for n, (v, _) in files.items()}
areas = [5, 6, 7, 9, 11, 13, 15]
gain_db = -20 - float(np.median([loud[n] for n in areas]))
peak = max(np.abs(v).max() for v, _ in files.values())
gain_db = min(gain_db, -0.5 - 20 * np.log10(peak))       # never clip
g = 10 ** (gain_db / 20)
rng = np.random.default_rng(26)
os.makedirs(out, exist_ok=True)
open(os.path.join(out, 'Xeno Crisis.msu'), 'wb').close()
total = 0
for n in range(1, 27):
    v, lp = files[n]
    s = v * g * 32768 + rng.random(v.shape) - rng.random(v.shape)
    s = np.clip(np.round(s), -32768, 32767).astype('<i2')
    open(os.path.join(out, 'Xeno Crisis-%d.pcm' % n), 'wb').write(b'MSU1' + struct.pack('<I', lp) + s.tobytes())
    total += len(s)
    print('%2d  %8.3f s  loop point %6.3f s  %5.1f LUFS  peak %5.1f dBFS' % (n, len(s) / 44100, lp / 44100, loud[n] + gain_db, 20 * np.log10(max(np.abs(s).max(), 1) / 32768)))
print('common gain %+.2f dB; %.1f min' % (gain_db, total / 44100 / 60))
