#!/bin/sh
# Read-only sweep of settings keys in one BLE session.
cd "$(dirname "$0")/.."
.venv/bin/python tools/ohw.py read ${KEYS:-0203 0207 0208 0209 020a 020b 020c 020e 020f 0210 0211 0217 0218 021e 021f 0227 024f 0254 0260 026a 029d 0213 0241} 2>&1 | grep -E "^0x|not found|timed out|handshake"
