"""Push text into the watch's AI chat via AUDIO_TEXT 0x0410 (BleVoice: category, status, mode, emotion, time6, len BE16, utf8)."""
import asyncio, sys, os, struct, time
from datetime import datetime
sys.path.insert(0, os.path.dirname(__file__))
import ohw

def voice(category, status, text, mode=0, emotion=0):
    t = datetime.now(); b = text.encode()[:512]
    return bytes([category, status, mode, emotion, t.year - 2000, t.month, t.day, t.hour, t.minute, t.second]) + struct.pack(">H", len(b)) + b

async def main():
    async with ohw.Watch(verbose=False) as w:
        await w.handshake(wait_info=True); await asyncio.sleep(1)
        steps = [
            ("you asked (input, normal)", voice(0, 0, "What's the weather like?")),
            ("answer (output, normal)", voice(1, 0, "Hi from your Mac! It's 28°C and cloudy in Sangotedo.")),
            ("answer streaming (output, going)", voice(1, 2, "This line was sent by OHW Studio…")),
            ("answer done (output, end)", voice(1, 3, "This line was sent by OHW Studio. 👋")),
            ("emotion (happy?)", voice(2, 0, "", emotion=1)),
        ]
        for label, d in steps:
            await w.send(0x0410, 0x00, d)
            r = await w.wait(0x0410, 2)
            print(f"{time.strftime('%H:%M:%S')}  {label:36s} ack={r is not None}")
            await asyncio.sleep(4)
        t0 = time.monotonic()
        while time.monotonic() - t0 < 5:
            try: k, fl, d = await asyncio.wait_for(w.q.get(), 0.5)
            except asyncio.TimeoutError: continue
            print(f"  watch sent {k:04x} fl={fl:02x} {d[:40].hex()}")
        print("done")

asyncio.run(main())
