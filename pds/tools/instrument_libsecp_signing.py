#!/usr/bin/env python3
"""Add the one S3-A raw-s capture immediately before upstream low-S normalization."""

import pathlib
import sys


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: instrument_libsecp_signing.py <ecdsa_impl.h>")
    path = pathlib.Path(sys.argv[1])
    text = path.read_text()
    declaration = (
        "static secp256k1_scalar medaka_captured_raw_s;\n"
        "static unsigned int medaka_raw_s_capture_count;\n\n"
    )
    function = "static int secp256k1_ecdsa_sig_sign("
    capture = "    high = secp256k1_scalar_is_high(sigs);"
    if text.count(function) != 1 or text.count(capture) != 1:
        raise SystemExit("libsecp256k1 signing capture point drifted")
    text = text.replace(function, declaration + function, 1)
    text = text.replace(
        capture,
        "    medaka_captured_raw_s = *sigs;\n"
        "    medaka_raw_s_capture_count++;\n" + capture,
        1,
    )
    path.write_text(text)


if __name__ == "__main__":
    main()
