#!/usr/bin/env python3
import os
import sys

import cv2
import easyocr
import numpy as np


LANGUAGE_CODES = {
    "chi_sim": "ch_sim",
    "chi_tra": "ch_tra",
    "eng": "en",
}


def main() -> int:
    image_bytes = sys.stdin.buffer.read()
    if not image_bytes:
        return 1

    image = cv2.imdecode(np.frombuffer(image_bytes, dtype=np.uint8), cv2.IMREAD_COLOR)
    if image is None:
        return 1

    configured = os.environ.get("OMARCHY_OCR_LANGS", "chi_sim+eng")
    languages = [
        LANGUAGE_CODES.get(language.strip(), language.strip())
        for language in configured.split("+")
        if language.strip()
    ]
    if not languages:
        languages = ["ch_sim", "en"]

    reader = easyocr.Reader(languages, gpu=False, verbose=False)
    detected = reader.readtext(image, detail=0, paragraph=True)
    text = "\n".join(str(line).strip() for line in detected if str(line).strip())
    if not text:
        return 1

    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())