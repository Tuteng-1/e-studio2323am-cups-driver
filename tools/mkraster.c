/*
 * mkraster.c — 生成测试用 CUPS raster（8bpp K），用于验证 rastertoestudio
 *
 *   ./mkraster out.raster [width] [height] [pages] [page_pt_w] [page_pt_h]
 *
 * 图案：白底 + 1px 外框 + 对角黑线 + 左上角 page×16 大小的黑块 + 右侧 8 级灰阶条
 * 第 N 页的左上角黑块高度是 N×16，用来验证多页/双面顺序。
 */
#include <cups/cups.h>
#include <cups/raster.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char *argv[])
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s out.raster [w] [h] [pages] [page_pt_w] [page_pt_h]\n",
                argv[0]);
        return 1;
    }
    int w = (argc > 2) ? atoi(argv[2]) : 800;
    int h = (argc > 3) ? atoi(argv[3]) : 1000;
    int pages = (argc > 4) ? atoi(argv[4]) : 1;
    int pw = (argc > 5) ? atoi(argv[5]) : 595;
    int ph = (argc > 6) ? atoi(argv[6]) : 842;
    if (pages < 1) pages = 1;

    FILE *f = fopen(argv[1], "wb");
    if (!f) { perror("fopen"); return 1; }

    cups_raster_t *r = cupsRasterOpen(fileno(f), CUPS_RASTER_WRITE);
    if (!r) { fprintf(stderr, "cupsRasterOpen failed\n"); return 1; }

    cups_page_header2_t hdr;
    memset(&hdr, 0, sizeof(hdr));
    hdr.cupsWidth = (unsigned)w;
    hdr.cupsHeight = (unsigned)h;
    hdr.cupsBitsPerPixel = 8;
    hdr.cupsBytesPerLine = (unsigned)w;
    hdr.cupsColorSpace = CUPS_CSPACE_K;
    hdr.cupsNumColors = 1;
    hdr.cupsCompression = 0;             /* CUPS_COMPRESS_NONE */
    hdr.HWResolution[0] = 600;
    hdr.HWResolution[1] = 600;
    hdr.PageSize[0] = (unsigned)pw;
    hdr.PageSize[1] = (unsigned)ph;

    unsigned char *row = malloc((size_t)w);
    if (!row) return 1;

    for (int p = 0; p < pages; p++) {
        if (!cupsRasterWriteHeader2(r, &hdr)) {
            fprintf(stderr, "cupsRasterWriteHeader2 failed (page %d)\n", p + 1);
            return 1;
        }

        int block = (p + 1) * 16;

        for (int y = 0; y < h; y++) {
            memset(row, 0, (size_t)w);                 /* 0 = 白 */

            for (int x = 0; x < w; x++) {
                int v = 0;
                if (x == 0 || x == w - 1 || y == 0 || y == h - 1) v = 255;
                if (x < 16 && y < block) v = 255;
                if (x == (y * w) / (h ? h : 1)) v = 255;
                /* 右侧 8 级灰阶 */
                if (x >= w - 80 && x < w - 8) {
                    int step = (x - (w - 80)) / 9;
                    v = step * 36;
                    if (v > 255) v = 255;
                }
                row[x] = (unsigned char)v;
            }
            if (cupsRasterWritePixels(r, row, (unsigned)w) != (unsigned)w) {
                fprintf(stderr, "short write at page %d line %d\n", p + 1, y);
                break;
            }
        }
    }

    free(row);
    cupsRasterClose(r);
    fclose(f);
    fprintf(stderr, "wrote %s (%dx%d, %d page%s)\n", argv[1], w, h, pages,
            pages > 1 ? "s" : "");
    return 0;
}
