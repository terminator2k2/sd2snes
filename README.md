sd2snes MK3 Carts Only
======================

## What This Fork Adds

- **SPC7110:**
- **Sufami Turbo:** 
- **Menu music:** play an `.spc` track in the background while browsing.
- **IPS/BPS patches:** choose translation, hack or fix patches before a game starts, without changing the ROM file on the SD card.
- **Cheat manager:** the original sd2snes already applies cheats — this fork adds a menu to **enable and disable** a game's codes on the console (from `/sd2snes/cheats/<rom>.yml`), without editing the YAML on a PC. Ready-made cheats can be exported from [gamehacking.org](https://gamehacking.org/system/snes)
- **Delete file and savegame:** delete the selected file or just its save (`.srm`) straight from the menu, without removing the SD card.
- **Reset to menu improvements:** return to the same folder or even the same ROM after a short reset.


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

## Menu Music

The menu can play background music while you browse. The file must be an **`.spc`** file named `menu.spc` and placed here:

```text
/sd2snes/menu.spc
```

To add music:

1. Download an `.spc` file.
2. Rename it to `menu.spc`.
3. Copy it into the `/sd2snes/` folder on your SD card.
4. Turn on the console.

Good places to find `.spc` files:

- [snesmusic.org](https://snesmusic.org)
- [zophar.net/music](https://www.zophar.net/music/nintendo-snes-spc)

You can turn menu music on or off in **Configuration → Browser Settings → Menu music**.

> [!TIP]
> Some soundtracks are downloaded as `.rsn` files. An `.rsn` is usually an archive that contains several `.spc` files. Extract it and choose one `.spc` from inside.

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


### Credits

The IPS/BPS patch support and the original reset-to-menu work come from [@Xeroxxx](https://github.com/mrehkopf/sd2snes/pull/293), with changes made in this fork.

Original sd2snes repository contributors listed by GitHub:

- [@ludufre](https://github.com/ludufre)
- [@mrehkopf](https://github.com/mrehkopf)
- [@RedGuyyyy](https://github.com/RedGuyyyy)
- [@github-user-name](https://github.com/github-user-name)
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

Fork-specific changes:
Copyright (C) 2026 Luan Freitas and contributors

Source code for all distributed binaries/releases is available in this repository and corresponding Git tags/releases, in accordance with GPL requirements.

See the [Original README](https://github.com/mrehkopf/sd2snes/blob/master/README.md).

See [FURiOUS's README](README.Savestates.FURiOUS.md) for information on Save States.

