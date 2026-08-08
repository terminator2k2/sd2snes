<h1> sd2snes</h1>

## What This Fork Adds

- **Menu music:** play an `.spc` track in the background while browsing.
- **Menu sounds:** optional navigation sound effects (cursor, confirm, back, error) that play on the cartridge's audio DAC, independent of the music.
- **IPS/BPS patches:** choose translation, hack or fix patches before a game starts, without changing the ROM file on the SD card.
- **Cheat manager:** the original sd2snes already applies cheats — this fork adds a menu to **enable and disable** a game's codes on the console (from `/sd2snes/cheats/<rom>.yml`), without editing the YAML on a PC. Ready-made cheats can be exported from [gamehacking.org](https://gamehacking.org/system/snes) as "FXPak Pro 1.7 (.yml)", or downloaded automatically by the **sd2snes Covers** app (matched by CRC32).
- **Delete file and savegame:** delete the selected file or just its save (`.srm`) straight from the menu, without removing the SD card.
- **Reset to menu improvements:** return to the same folder or even the same ROM after a short reset.
- **SPC7110 WIP Support:**


## IPS/BPS Patches

This fork can apply **IPS** and **BPS** patches when a game loads. This is useful for fan translations, hacks and fixes.

Your ROM file on the SD card is not changed. The patch is applied only while the game is being loaded.

Put the patch in the same folder as the ROM. Its filename must start with the ROM filename, without the ROM extension, and end in `.ips` or `.bps`:

```text
/sd2snes/A/Aladdin (USA).sfc
/sd2snes/A/Aladdin (USA).ips
/sd2snes/A/Aladdin (USA) (Hack).bps
```

When you open a game with matching patches, the menu shows a patch selector:

- **`[No patch]`** starts the game normally.
- Choose a patch to use it for this boot.
- Up to **8** patches are shown for each game.

## Menu Music and Sounds

The menu can play **background music** while you browse, plus four optional **navigation sound effects** (cursor, confirm, back, error). They only play in the menu and never affect your games.

The easiest way to set both up is the web **Sound Creator**: pick the music, make the effects, and download the files ready to copy to the card. Everything runs in your browser — nothing is uploaded.

### 👉 [sd2snes.ludufre.com/sounds](https://sd2snes.ludufre.com/sounds/)

### Background music (`menu.spc`)

The music is an **`.spc`** file named `menu.spc`, placed here:

```text
/sd2snes/menu.spc
```

To add music by hand:

1. Download an `.spc` file.
2. Rename it to `menu.spc`.
3. Copy it into the `/sd2snes/` folder on your SD card.
4. Turn on the console.

Good places to find `.spc` files:

- [snesmusic.org](https://snesmusic.org)
- [zophar.net/music](https://www.zophar.net/music/nintendo-snes-spc) — has an MP3 preview for each track, so you can listen before downloading.

Turn the music on or off in **Configuration → Browser Settings → Menu music**.

You can also choose the music **without renaming anything**: highlight any **`.spc`** in the file browser, press **Y** for the context menu and choose **Set as menu music**. The menu reloads with that track as the new background music and remembers it across reboots; `/sd2snes/menu.spc` stays as the fallback. To go back to it, use **Configuration → Browser Settings → Restore music**.

> [!TIP]
> Some soundtracks are downloaded as `.rsn` files. An `.rsn` is usually an archive that contains several `.spc` files. Extract it and choose one `.spc` from inside.

### Navigation sounds (effects)

Four short, optional effects play as you move through the menu. Each is a separate file in `/sd2snes/`:

| File | Plays when |
| --- | --- |
| `sfx_cursor.pcm` | the cursor moves |
| `sfx_confirm.pcm` | you open or confirm (A) |
| `sfx_back.pcm` | you go back (B) |
| `sfx_error.pcm` | an action is not allowed |

These are **MSU‑1 PCM** files (16‑bit stereo, 44.1 kHz). They play on the cartridge's audio DAC, so they never interrupt the `.spc` music. A default set ships with the firmware, so the menu has sounds out of the box — use the Sound Creator above to customize or replace them. (A missing file just means that effect stays silent.)

Turn the effects on or off in **Configuration → Browser Settings → Menu sounds**.

## Cheats

The original sd2snes firmware already **applies** cheats per game. What this fork adds is a **cheat manager in the menu**, so you can enable and disable individual codes on the console — without editing the YAML on a PC.

Cheats are read from a **YAML** file (`.yml`) in the `/sd2snes/cheats/` folder, named after the ROM (its extension replaced by `.yml`):

```text
/sd2snes/A/Aladdin (USA).sfc        ← the ROM (in any folder)
/sd2snes/cheats/Aladdin (USA).yml   ← its cheats
```

To manage them, highlight a ROM in the file browser, press **Y** for the context menu and choose **Cheats**. The list shows every code in the file:

- **A** enables or disables the highlighted code.
- **B** saves your changes and exits.

Enabled codes are applied the next time you start that game.

To get ready-made cheat files:

1. Open [gamehacking.org/system/snes](https://gamehacking.org/system/snes) and find your game.
2. Export its codes using the **FXPak Pro 1.7 (.yml)** format.
3. Rename the file to match the ROM and drop it in `/sd2snes/cheats/` on the SD card.

> [!TIP]
> The **[sd2snes Covers](https://github.com/ludufre/sd2snes-covers)** app can fetch ready-made cheats automatically — it matches each ROM by CRC32 and saves `<rom>.yml` files into a `cheats/` folder, ready to copy into `/sd2snes/cheats/`.

> [!NOTE]
> If a ROM has no `.yml` in `/sd2snes/cheats/` (or the file has no codes), the menu shows a "no cheats for this ROM" message.

## Delete File and Savegame

You can delete files and saves straight from the menu, without removing the SD card or using a computer.

Highlight a file in the browser and press **Y** for the context menu:

- **Delete:** removes the selected file.
- **Delete save:** removes only the `.srm` savegame for that ROM, keeping the ROM itself.

> [!WARNING]
> Deletion is permanent — there is no recycle bin on the SD card. Double-check the selected file before confirming.

## Reset to Menu

The reset button can bring you back to the sd2snes menu instead of simply restarting the game. This fork adds two options that make returning to your game list easier.

Set it in **Configuration → In-game Settings → Reset to menu**:

- **Off:** reset behaves like a normal SNES reset.
- **On:** a short reset returns to the menu.
- **Folder:** returns to the menu and opens the folder of the game you were playing.
- **ROM:** returns to the folder and highlights the ROM you were playing.

The **Folder** and **ROM** options work after a reset back to the menu. A full power-on still starts from the normal top-level menu.


## Common Problems

**The menu did not change after installing.**

Check that you used the matching **full** release and copied its files to the root of the SD card. If you used a non-full package, check that the matching official firmware was installed first and that this fork's files were copied into `/sd2snes`.

**Covers do not appear.**

Check that covers are enabled, that each `.cov` file has the same name as its ROM, and that the covers were generated with **sd2snes-covers v1.1.0 or newer**.

**Menu music is silent.**

Check that the file is named exactly `menu.spc`, is placed at `/sd2snes/menu.spc`, and is really an `.spc` file. MP3 and WAV files do not work.

**Navigation sounds are silent.**

Check that **Menu sounds** is turned on, and that `sfx_cursor.pcm`, `sfx_confirm.pcm`, `sfx_back.pcm` and `sfx_error.pcm` are in `/sd2snes/` and are **MSU‑1 PCM** files. They ship with the firmware; if you removed them, copy them back from the release package or recreate them with the [Sound Creator](https://sd2snes.ludufre.com/sounds/).

**A patch does not appear.**

Check that the patch is in the same folder as the ROM, starts with the ROM filename, and ends in `.ips` or `.bps`.


### Cover Format

This firmware, starting with **v1.11.2-br-2.1**, uses the newer OBJ-sprite `.cov` cover format. Covers generated by older versions of the cover app will not display correctly. Regenerate them with **sd2snes-covers v1.1.0 or newer**.

### BPS Patch Integrity Check

The BPS integrity check can be enabled from **Configuration → Patch Options → Verify Integrity**.

This option is **Off by default**. When enabled, the firmware re-reads the ROM after applying a BPS patch to confirm it was applied correctly. This makes BPS loading slower; for example, a 4 MB BPS patch can add around 15 seconds of loading time on average. IPS patches are not verified by this option.

### Menu Music and Sound Limitations

For the music, only `.spc` files are supported. An `.spc` file is not a normal audio recording; it is a snapshot of the SNES sound chip state and is capped at 64 KB. There is no direct MP3-to-SPC conversion — the Sound Creator lets you pick and preview an `.spc`, it does not generate one from other audio.

When music loads at boot, after a reset or after turning the option on, the menu may pause briefly while the file is uploaded to the SNES sound chip. Opening an `.spc` from the file browser pauses the background music and resumes it when you return with the B button.

The navigation effects are separate: they are short **MSU‑1 PCM** clips played on the cartridge's audio DAC (16‑bit stereo, 44.1 kHz), so the music keeps playing on the SNES sound chip while an effect fires. Keep them short (well under a second) so they feel snappy.



### Credits

The IPS/BPS patch support and the original reset-to-menu work come from [@Xeroxxx](https://github.com/mrehkopf/sd2snes/pull/293), with changes made in this fork.

The in-game cheat menu work come from [@Relikk](https://github.com/Relikk).

Original sd2snes repository contributors listed by GitHub:

- [@mrehkopf](https://github.com/mrehkopf)
- [@RedGuyyyy](https://github.com/RedGuyyyy)
- [@@ludufre](https://github.com/ludufre/sd2snes)
- [@Relikk](https://github.com/Relikk)
- [@furious](https://github.com/furious)
- [@redacted173](https://github.com/redacted173)
- [@francois-berder](https://github.com/francois-berder)
- [@Godzil](https://github.com/Godzil)
- [@mlarouche](https://github.com/mlarouche)
- [@devinacker](https://github.com/devinacker)
- [@Xeroxxx](https://github.com/Xeroxxx)
- [@tcprescott](https://github.com/tcprescott)
- [@freelancer42](https://github.com/freelancer42)
- [@LuigiBlood](https://github.com/LuigiBlood)
- [@DevLaTron](https://github.com/DevLaTron)
- [@gasparitiago](https://github.com/gasparitiago)

### Source Code and License

This project remains licensed under the GNU General Public License v2.0 (GPL-2.0), following the original sd2snes project license.

All original copyrights belong to their respective authors and contributors.
