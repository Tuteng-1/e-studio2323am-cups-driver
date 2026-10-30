#!/usr/bin/env python3
"""
tools/replay.py — 把抓包还原成 CUPS raster，再跑一遍 filter，逐字节对比

    python3 tools/replay.py <captures_dir> <filter> <template.raster>

原理：
  1. 每个 .prn 先用 tools/prncheck --pbm 解码成 PBM（整页 1bpp）；
  2. 按抓包里的 PAPERWIDTH/PAPERLENGTH 裁掉四边 99 px 的可印区边距，
     得到 Windows 驱动 DC 里的那张位图；
  3. 用模板 raster 的 424 字节头（由 cupsfilter 产生）拼一份新的 CUPS raster；
  4. 按抓包里的 PAPER / MEDIASOURCE / ORIENTATION / COPYEND 选 filter 选项；
  5. 比较 filter 输出与原始 .prn，只忽略 TIMESTAMP（时间不可能相同）。

  300dpi（PAPERWIDTH=4960）和 100x150 自定义纸（JPOST 但尺寸与 PPD 不同）
  这类抓包无法用 PPD 的固定纸型精确重放，会被跳过并说明原因。
"""

import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

MARGIN = 99   # 600dpi 下 Windows 驱动 / PPD *ImageableArea 的四边边距
HDR = 1800    # cups_page_header2_t 的线上大小（含 16 个字符串字段）

# PAPER -> (PPD option, width_px, height_px)
PAPERS = {
    "A4":     ("A4",     4961, 7016),
    "A5":     ("A5",     3496, 4961),
    "A3":     ("A3",     7016, 9921),
    "LETTER": ("Letter", 5100, 6600),
    "LEGAL":  ("Legal",  5100, 8400),
    "LEDGER": ("Tabloid", 6600, 10200),
    "INVOICE": ("Statement", 3300, 5100),
    "13LG":   ("FanFoldGermanLegal", 5100, 7800),
    "ENV_10": ("Env10",  2476, 5700),
    "ENV_DL": ("EnvDL",  2598, 5197),
    "ENV_C5": ("EnvC5",  3827, 5410),
    "ENV_MONARCH": ("EnvMonarch", 2324, 4500),
    "JPOST":  ("Postcard", 2362, 3496),
    "85SQ":   ("8.5x8.5", 5100, 5105),
}

SLOTS = {
    "TRAY1": "Tray1",
    "TRAY2": "Tray2",
    "MANUALFEED": "Bypass",
    "AUTO": "Auto",
}

MEDIA = {
    "PAPER": "Plain",
    "THIN": "Thin",
    "THICK": "Thick",
    "ENVELOPE": "Envelope",
    "TRANSPARENCY": "Transparency",
    "RECYCLE": "Recycle",
}


def pjl(data, key):
    m = re.search(rb"@PJL SET " + key.encode() + rb"=([^\r\n]*)", data)
    return m.group(1).decode("latin1") if m else None


def split_jobs(data):
    starts = [m.start() for m in re.finditer(rb"\x1b%-12345X@PJL", data)]
    if not starts:
        return [data]
    jobs = []
    for i, s in enumerate(starts):
        e = starts[i + 1] if i + 1 < len(starts) else len(data)
        jobs.append(data[s:e])
    return jobs


def read_pbm(path):
    d = open(path, "rb").read()
    m = re.match(rb"P4\s+(\d+)\s+(\d+)\s", d)
    if not m:
        raise ValueError("bad PBM " + path)
    w, h = int(m.group(1)), int(m.group(2))
    row = (w + 7) // 8
    return w, h, d[m.end():]


def crop_page(pbm_path, page_w, page_h):
    w, h, body = read_pbm(pbm_path)
    if w != page_w or h != page_h:
        raise ValueError("PBM %dx%d != page %dx%d" % (w, h, page_w, page_h))
    cw, ch = w - 2 * MARGIN, h - 2 * MARGIN
    srow = (w + 7) // 8
    drow = (cw + 7) // 8
    out = bytearray()
    mask = (1 << cw) - 1
    for y in range(MARGIN, MARGIN + ch):
        s = body[y * srow:(y + 1) * srow]
        v = int.from_bytes(s, "big")
        c = (v >> (srow * 8 - (MARGIN + cw))) & mask
        out += (c << (drow * 8 - cw)).to_bytes(drow, "big")
    return cw, ch, bytes(out)


def make_raster(tpl, pages, page_w, page_h, opt):
    cw, ch = page_w - 2 * MARGIN, page_h - 2 * MARGIN
    bpl = (cw + 7) // 8
    hdr = bytearray(tpl[:HDR])

    def put(off, val):
        struct.pack_into("<I", hdr, off, val)

    put(276, 0)                 # Duplex
    put(280, 600); put(284, 600)
    put(288, 0); put(292, 0); put(296, page_h); put(300, page_w)
    put(316, 0); put(320, 0)    # Margins
    put(344, 1)                 # NumCopies
    put(348, 0)                 # Orientation
    put(356, round(page_w * 72 / 600)); put(360, round(page_h * 72 / 600))
    put(376, cw); put(380, ch)
    put(384, 0)                 # cupsMediaType
    put(388, 1)                 # cupsBitsPerColor
    put(392, 1)                 # cupsBitsPerPixel
    put(396, bpl)
    put(400, 0)                 # cupsColorOrder = chunked
    put(404, 3)                 # cupsColorSpace = K
    put(408, 0)                 # cupsCompression
    put(412, 0); put(416, 0); put(420, 0)
    put(424, 1)                 # cupsNumColors
    hdr[1736:1800] = b"\0" * 64
    hdr[1736:1736 + len(opt)] = opt.encode()  # cupsPageSizeName

    out = bytearray()
    for i, p in enumerate(pages):
        if len(p) != bpl * ch:
            raise ValueError("page bitmap size %d != %d" % (len(p), bpl * ch))
        # CUPS raster 每页一个页头：仅第一页带 4 字节 sync（"3SaR"），
        # 其后的页头是 1796 字节的结构体本体（libcups 的写法）。
        out += hdr if i == 0 else hdr[4:]
        out += p
    return bytes(out)


def normalize(data):
    return re.sub(rb"@PJL SET TIMESTAMP=[^\r\n]*\r\n", b"", data)


def first_diff(a, b):
    n = min(len(a), len(b))
    for i in range(n):
        if a[i] != b[i]:
            return i
    return n if len(a) != len(b) else -1


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        return 2

    capdir, filt, tpl_path = sys.argv[1:4]
    tpl = open(tpl_path, "rb").read()
    if tpl[:4] != b"3SaR":
        print("template is not a little-endian CUPS raster: %r" % tpl[:4])
        return 2

    prncheck = os.path.join(os.path.dirname(filt) or ".", "tools", "prncheck")
    if not os.path.exists(prncheck):
        prncheck = "./tools/prncheck"

    tests = sorted(f for f in os.listdir(capdir) if f.endswith(".prn"))
    passed = skipped = failed = 0
    tmp = tempfile.mkdtemp(prefix="estudio-replay.")

    try:
        for name in tests:
            data = open(os.path.join(capdir, name), "rb").read()
            paper = pjl(data, "PAPER")
            pw = int(pjl(data, "PAPERWIDTH") or 0)
            ph = int(pjl(data, "PAPERLENGTH") or 0)
            ori = pjl(data, "ORIENTATION")
            src = pjl(data, "MEDIASOURCE") or "AUTO"
            mtype = pjl(data, "MEDIATYPE") or "PAPER"
            user = pjl(data, "USERNAME") or "cups"

            if paper not in PAPERS:
                print("SKIP %-32s 未知 PAPER=%s" % (name, paper))
                skipped += 1
                continue

            opt, ew, eh = PAPERS[paper]
            if (pw, ph) != (ew, eh):
                print("SKIP %-32s 抓包 %dx%d 与 PPD %s(%dx%d) 不一致"
                      % (name, pw, ph, opt, ew, eh))
                skipped += 1
                continue

            jobs = split_jobs(data)
            pages_per_job = jobs[0].count(b"@PJL SET PAGESTATUS=START")
            copies = len(jobs)
            if pages_per_job < 1:
                print("SKIP %-32s 没有页" % name)
                skipped += 1
                continue

            pbm_dir = os.path.join(tmp, name)
            os.makedirs(pbm_dir, exist_ok=True)
            r = subprocess.run([prncheck, os.path.join(capdir, name),
                                "--pbm", pbm_dir],
                               stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL)
            if r.returncode != 0:
                print("SKIP %-32s prncheck 解码失败" % name)
                skipped += 1
                continue

            pages = []
            for i in range(1, pages_per_job + 1):
                cw, ch, bits = crop_page(os.path.join(pbm_dir, "page%02d.pbm" % i),
                                         pw, ph)
                pages.append(bits)

            raster = make_raster(tpl, pages, pw, ph, opt)
            raster_path = os.path.join(tmp, name + ".raster")
            open(raster_path, "wb").write(raster)

            opts = ["PageSize=" + opt]
            if src in SLOTS:
                opts.append("InputSlot=" + SLOTS[src])
            if mtype in MEDIA:
                opts.append("MediaType=" + MEDIA[mtype])
            if ori == "LANDSCAPE":
                opts.append("orientation-requested=4")

            out_path = os.path.join(tmp, name + ".out")
            with open(out_path, "wb") as out:
                r = subprocess.run([filt, "1", user, "replay", str(copies),
                                    " ".join(opts), raster_path],
                                   stdout=out)
            if r.returncode != 0:
                print("FAIL %-32s filter 退出码 %d" % (name, r.returncode))
                failed += 1
                continue

            got = open(out_path, "rb").read()
            want = data
            ng, nw = normalize(got), normalize(want)
            if ng == nw:
                print("ok   %-32s %d 页 x %d 份"
                      % (name, pages_per_job, copies))
                passed += 1
            else:
                i = first_diff(ng, nw)
                lo = max(0, i - 24)
                print("FAIL %-32s 首个差异 @%d (ours %d / device %d)"
                      % (name, i, len(ng), len(nw)))
                print("     ours  :", ng[lo:i + 24].hex(" "))
                print("     device:", nw[lo:i + 24].hex(" "))
                failed += 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("\n重放：%d 通过, %d 失败, %d 跳过" % (passed, failed, skipped))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
