# Xeno Crisis MSU-1 packs (sd2snes / FXPAK Pro, `fpga_xc_msu.bi3`)

With an MSU-1 pack next to the ROM, the sd2snes plays the music from the pack instead of decoding the game's own Opus streams. The sound effects still come from the game.

## Files

Standard MSU-1 layout, named after the ROM file (here `Xeno Crisis.sfc`):

| File | Content |
|---|---|
| `Xeno Crisis.msu` | Must exist. Its content is not used (the game reads no MSU-1 data); an empty file is fine. |
| `Xeno Crisis-<n>.pcm` | Track n: `MSU1`, a 32-bit little-endian loop point in samples, then 44.1 kHz 16-bit signed little-endian stereo. |

On the card, `/sd2snes/fpga_xc_msu.bi3` must be present as well. Without it (or without the `.msu`), the game uses its own music as before.

## Track numbers

Track n is the game's music stream n. The length is the game's own version, for reference; a pack's tracks may be longer or shorter.

| n | Game track | Game length | Notes |
|---|---|---|---|
| 1 | MUSIC_0_INTRO_VOICED | 0:15.8 | Played once (boot intro). |
| 2 | MUSIC_10_ALARM | 0:02.7 | |
| 3 | MUSIC_1_TITLE | 0:18.2 | Loops. |
| 4 | MUSIC_2_INGAME_0_INTRO | 0:01.4 | Intro of 5. |
| 5 | MUSIC_2_INGAME_0_LOOP | 0:53.5 | Loops. |
| 6 | MUSIC_2_INGAME_1 | 1:19.9 | |
| 7 | MUSIC_2_INGAME_2 | 1:04.3 | |
| 8 | MUSIC_2_INGAME_3_INTRO | 0:05.3 | Intro of 9. |
| 9 | MUSIC_2_INGAME_3_LOOP | 0:58.7 | |
| 10 | MUSIC_2_INGAME_4_INTRO | 0:11.4 | Intro of 11. |
| 11 | MUSIC_2_INGAME_4_LOOP | 0:40.7 | |
| 12 | MUSIC_2_INGAME_5_INTRO | 0:04.1 | Intro of 13. |
| 13 | MUSIC_2_INGAME_5_LOOP | 0:58.0 | |
| 14 | MUSIC_2_INGAME_6_INTRO | 0:16.0 | Intro of 15. |
| 15 | MUSIC_2_INGAME_6_LOOP | 0:54.3 | |
| 16 | MUSIC_3_BOSS_0 | 0:28.7 | |
| 17 | MUSIC_3_BOSS_1 | 0:17.9 | |
| 18 | MUSIC_3_BOSS_2_INTRO | 0:00.4 | Intro of 19. |
| 19 | MUSIC_3_BOSS_2_LOOP | 0:20.4 | |
| 20 | MUSIC_3_BOSS_3 | 0:22.6 | |
| 21 | MUSIC_4_CUTSCENE | 0:22.1 | |
| 22 | MUSIC_5_SHOP | 0:11.2 | |
| 23 | MUSIC_6_CONTINUE | 0:17.4 | |
| 24 | MUSIC_7_STAGE_CLEAR | 0:03.6 | |
| 25 | MUSIC_8_GAME_OVER | 0:06.0 | |
| 26 | MUSIC_9_ENDING | 1:00.0 | |

## How tracks are played

- **Looping:** the game decides whether a track loops. A looping track plays with MSU-1 repeat, so set the `.pcm` loop point where the loop should restart (0 = the whole track, which is what the game itself does). A track the game plays once (the voiced intro, jingles) ignores the loop point.
- **Intro + loop pairs** (4/5, 8/9, 10/11, 12/13, 14/15, 18/19): the intro plays once, and the loop part starts as soon as the intro `.pcm` ends. The intro's length does not have to match the game's. If the soundtrack has the two parts as one piece, either split it at the same point, or put the whole piece in the loop track with a loop point after the intro and an empty or very short intro track.
- **Missing tracks** are silent; the game carries on.
- **Pausing** the game pauses the MSU-1 track, and unpausing continues it.
- **Level:** the music plays at full MSU-1 volume. Normalize the pack the way MSU-1 packs usually are; the sd2snes menu's MSU-1 volume boost setting applies.

Saving works as usual (`.srm`). While a pack is used, the firmware checks the save RAM once a second during play and writes the `.srm` when it changed.
