"""Synthesize a UTF-8 text file to MP3 with edge-tts.

Usage: python edge_say.py <text_file> <mp3_file> [voice] [rate]

Trusts ca-bundle.pem next to this file (certifi roots + every root Windows trusts),
because TLS-inspecting antivirus or corporate proxies re-sign HTTPS traffic and
edge-tts only trusts certifi's bundle.
"""
import asyncio
import pathlib
import sys

import certifi

BUNDLE = pathlib.Path(__file__).with_name("ca-bundle.pem")
if BUNDLE.exists():
    certifi.where = lambda: str(BUNDLE)

import edge_tts  # noqa: E402  - must be imported after the certifi patch

DEFAULT_VOICE = "en-US-AriaNeural"


async def synthesize(text_file, mp3_file, voice=DEFAULT_VOICE, rate="+0%"):
    text = pathlib.Path(text_file).read_text(encoding="utf-8-sig")
    await edge_tts.Communicate(text, voice, rate=rate).save(mp3_file)


if __name__ == "__main__":
    asyncio.run(synthesize(*sys.argv[1:]))
