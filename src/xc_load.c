/* Xeno Crisis on sd2snes: build the sd2snes_xc memory image from the cartridge's two parts at load time.
 *
 * The user loads the SNES ROM (the cartridge's 128 KB kernel, "XENOCRISIS", maker BM, game XCRI, chipset $63)
 * like any other game. load_rom() puts it at PSRAM 0; then xc_load_image() adds, from the SD card:
 *
 *   /sd2snes/xenocrisis_rp2040.bin  the RP2040 flash dump (16 MB, supplied by the user, like the DSP or BS-X files)
 *   /sd2snes/xc_soc.bin             the soft CPU support files, shipped with the firmware next to fpga_xc.bi3:
 *                                   replacement bootrom and firmware additions (built with the firmware: src/xc_soc/)
 *
 * PSRAM layout (the same as src/xc_soc/xc_build_image.py produces, which remains usable: a file larger than 128 KB is
 * taken as such a prebuilt image and loaded as is):
 *
 *   0x000000-0x01FFFF  SNES kernel ROM
 *   0x020000-0xCFFFFF  RP2040 flash 0x020000-0xCFFFFF      (flash offset = PSRAM address)
 *   0xD00000-0xD1FFFF  RP2040 flash 0x000000-0x01FFFF
 *   0xD20000-0xD23FFF  replacement bootrom                 (soft CPU 0x00000000)
 *   0xD24000-0xD27FFF  firmware additions                  (RP2040 flash 0xF00000)
 *
 * Then the firmware functions listed in the additions' patch table are redirected in the PSRAM copy
 * (xc_patch_image.py does the same to a file). Without a .srm, the save area starts from the dump's
 * (RP2040 flash 0xFF8000-0xFFFFFF), so the saves made on the cartridge carry over.
 */
#include <string.h>
#include "config.h"
#include "uart.h"
#include "ff.h"
#include "diskio.h"
#include "fileops.h"
#include "spi.h"
#include "fpga_spi.h"
#include "smc.h"
#include "memory.h"
#include "xc_audio.h"
#include "fpga.h"

#define XC_FLASH_FILE  "/sd2snes/xenocrisis_rp2040.bin"
#define XC_SOC_FILE    "/sd2snes/xc_soc.bin"
#define XC_SOC_MAGIC   0x434F5358u     /* "XSOC" */
#define XC_FW_MAGIC    0x5843584Du     /* firmware additions header (xc_fw_header.c) */
#define XC_LAUNCH_CORE1 0x10059060u    /* multicore_launch_core1(): identifies the firmware build */

static uint8_t from_dump;              /* image built here: the dump's save area may seed the save RAM */

/* len bytes (a multiple of 512) from file offset off straight to the PSRAM at dst (SD DMA) */
static int offload(const char* fn, uint32_t off, uint32_t len, uint32_t dst)
{
  set_mcu_addr(dst);
  file_open((const uint8_t*)fn, FA_READ);
  if(file_res) return 0;
  ff_sd_offload = 1;
  f_lseek(&file_handle, off);
  while(len && !file_res) {
    ff_sd_offload = 1;
    sd_offload_tgt = 0;
    UINT n = file_read();
    if(!n) break;
    len -= n < len ? n : len;
  }
  file_close();
  return !file_res && !len;
}

static uint32_t psram_of(uint32_t flash_addr)
{
  uint32_t a = flash_addr - 0x10000000u;
  return a < 0x20000u ? 0xD00000u + a : a;
}

/* returns NULL when the image is complete, else the name of the file that is missing or wrong */
const char* xc_load_image(void)
{
  uint32_t h[4];
  from_dump = 0;

  file_open((const uint8_t*)XC_FLASH_FILE, FA_READ);
  uint32_t size = file_handle.fsize;
  file_close();
  printf("XC: %s %lu\n", XC_FLASH_FILE, size);
  if(file_res || size != 0x1000000u) return XC_FLASH_FILE;
  if(!offload(XC_FLASH_FILE, 0x020000u, 0xCE0000u, 0x020000u)) return XC_FLASH_FILE;
  if(!offload(XC_FLASH_FILE, 0x000000u, 0x020000u, 0xD00000u)) return XC_FLASH_FILE;
  if(sram_readshort(psram_of(XC_LAUNCH_CORE1)) != 0x4905) {
    printf("XC: unknown RP2040 build\n");
    return XC_FLASH_FILE;
  }

  file_open((const uint8_t*)XC_SOC_FILE, FA_READ);
  if(!file_res) file_readblock(h, 0, 16);
  file_close();
  if(file_res || h[0] != XC_SOC_MAGIC || h[1] != 1) return XC_SOC_FILE;
  if(!offload(XC_SOC_FILE, 0x200u, 0x8000u, 0xD20000u)) return XC_SOC_FILE;

  /* redirect the firmware functions (patch table after the additions' header) */
  file_open((const uint8_t*)XC_SOC_FILE, FA_READ);
  file_readblock(h, 0x4200u, 16);
  if(file_res || h[0] != XC_FW_MAGIC || h[1] < 2 || h[3] > 256) {
    file_close();
    return XC_SOC_FILE;
  }
  uint32_t count = h[3];
  for(uint32_t i = 0; i < count; i++) {
    uint32_t e[3];                                   /* flash address, target, kind */
    if(file_readblock(e, 0x4210u + i * 12, 12) != 12) break;
    uint32_t addr = e[0];
    if(e[2] == 0) {
      /* push {r0}; ldr r0, [pc, #k]; mov ip, r0; pop {r0}; bx ip; nop; .word target */
      uint32_t lit = (addr + 13) & ~3u;
      uint16_t code[6] = { 0xB401, 0x4800 | (uint16_t)((lit - ((addr + 6) & ~3u)) / 4), 0x4684, 0xBC01, 0x4760, 0xBF00 };
      sram_writeblock(code, psram_of(addr), 12);
      sram_writeblock(&e[1], psram_of(lit), 4);
    } else if(e[2] == 1) {
      sram_writeblock(&e[1], psram_of(addr + 12), 4);  /* existing veneer: new target */
    } else {
      uint16_t code[2] = { 0x2000, 0x4770 };           /* movs r0, #0; bx lr */
      sram_writeblock(code, psram_of(addr), 4);
    }
  }
  file_close();
  if(file_res) return XC_SOC_FILE;
  printf("XC: image ok, %lu patches\n", count);
  from_dump = 1;
  return NULL;
}

/* an MSU-1 pack next to the ROM (<rom>.msu, as msu1_check() looks for it) and the MSU-1 core on the card */
int xc_msu_pack(const uint8_t* filename)
{
  char name[260];
  const char* dot = strrchr((const char*)filename, '.');
  size_t n = dot ? (size_t)(dot - (const char*)filename) : strlen((const char*)filename);
  if(n > sizeof(name) - 5) return 0;
  memcpy(name, filename, n);
  strcpy(name + n, ".msu");
  file_open((const uint8_t*)name, FA_READ);
  file_close();
  if(file_res) { file_res = FR_OK; return 0; }
  file_open(FPGA_XC_MSU, FA_READ);
  file_close();
  if(file_res) {
    printf("XC: no %s\n", FPGA_XC_MSU);
    file_res = FR_OK;
    return 0;
  }
  printf("XC: MSU-1 %s\n", name);
  return 1;
}

/* no .srm yet: start from the save area of the dump (the saves made on the cartridge) */
void xc_load_dump_save(void)
{
  if(!from_dump) return;
  file_open((const uint8_t*)XC_FLASH_FILE, FA_READ);
  for(uint32_t off = 0; off < 0x8000u && !file_res; off += 512) {
    if(file_readblock(file_buf, 0xFF8000u + off, 512) != 512) break;
    sram_writeblock(file_buf, SRAM_SAVE_ADDR + off, 512);
  }
  file_close();
  printf("XC: save from dump\n");
}
