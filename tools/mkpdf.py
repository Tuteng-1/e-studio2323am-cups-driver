#!/usr/bin/env python3
"""
tools/mkpdf.py — 生成多页测试 PDF（每页一行 Helvetica 文字）

    python3 tools/mkpdf.py out.pdf [pages]

用来自测 "PDF -> cgpdftoraster -> rastertoestudio" 这条真实链路，
不依赖任何第三方 Python 库。
"""
import sys


def build(pages):
    objs = []
    # 对象编号：1 = Catalog, 2 = Pages, 3 = Font，之后每页两个：
    # 4+2i = Page，5+2i = Contents
    kids = " ".join("%d 0 R" % (4 + 2 * i) for i in range(pages))
    objs.append(b"<</Type/Catalog/Pages 2 0 R>>")
    objs.append(("<</Type/Pages/Kids[%s]/Count %d>>" % (kids, pages)).encode())
    objs.append(b"<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>")
    for i in range(pages):
        text = ("BT /F1 36 Tf 72 700 Td (TEST PAGE %d) Tj ET" % (i + 1)).encode()
        objs.append(("<</Type/Page/Parent 2 0 R/MediaBox[0 0 595 842]"
                     "/Resources<</Font<</F1 3 0 R>>>>/Contents %d 0 R>>"
                     % (5 + 2 * i)).encode())
        objs.append(b"<</Length %d>>stream\n" % len(text) + text + b"\nendstream")

    out = bytearray(b"%PDF-1.4\n")
    offs = []
    for i, body in enumerate(objs, 1):
        offs.append(len(out))
        out += b"%d 0 obj" % i + body + b"endobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
    for o in offs:
        out += b"%010d 00000 n \n" % o
    out += (b"trailer<</Root 1 0 R/Size %d>>\nstartxref\n%d\n%%%%EOF\n"
            % (len(objs) + 1, xref))
    return bytes(out)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    data = build(n)
    open(sys.argv[1], "wb").write(data)
    print("wrote %s (%d page%s, %d bytes)" % (sys.argv[1], n,
                                              "s" if n > 1 else "", len(data)))
