#!/usr/bin/env python3
"""Send controller and keyboard input to the composite Pico firmware."""
import argparse
import socket
import struct
import time

HOST = "192.168.4.60"
PORT = 39383
BUTTONS = {
    "A": 1 << 0, "B": 1 << 1, "X": 1 << 2, "Y": 1 << 3,
    "L": 1 << 4, "R": 1 << 5, "ZL": 1 << 6, "ZR": 1 << 7,
    "PLUS": 1 << 8, "START": 1 << 8, "MINUS": 1 << 9, "SELECT": 1 << 9,
    "HOME": 1 << 10, "CAPTURE": 1 << 11, "L3": 1 << 12, "R3": 1 << 13,
}
HATS = {"up": 0, "upright": 1, "right": 2, "downright": 3, "down": 4,
        "downleft": 5, "left": 6, "upleft": 7, "center": 8}


def packet(buttons=0, lx=0, ly=0, rx=0, ry=0, hat=8, text=""):
    encoded = text.encode("ascii")[:16]
    return struct.pack("<2sBB I hhhh B 16s", b"SW", 1, len(encoded), buttons,
                       lx, ly, rx, ry, hat, encoded)


def text_packets(text):
    data = text.encode("ascii")
    return [struct.pack("<2sBB I hhhh B 16s", b"SW", 2, len(data[i:i + 16]),
                        0, 0, 0, 0, 0, 8, data[i:i + 16])
            for i in range(0, len(data), 16)]


def send(packets, host, port, interval=0.0):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    for payload in packets:
        sock.sendto(payload, (host, port))
        if interval:
            time.sleep(interval)
    sock.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default=HOST)
    parser.add_argument("--port", type=int, default=PORT)
    sub = parser.add_subparsers(dest="command", required=True)
    state = sub.add_parser("state")
    state.add_argument("--buttons", nargs="*", default=[])
    state.add_argument("--hat", choices=HATS, default="center")
    state.add_argument("--lx", type=int, default=0)
    state.add_argument("--ly", type=int, default=0)
    state.add_argument("--rx", type=int, default=0)
    state.add_argument("--ry", type=int, default=0)
    tap = sub.add_parser("tap")
    tap.add_argument("buttons", nargs="+")
    tap.add_argument("--ms", type=int, default=80)
    text = sub.add_parser("text")
    text.add_argument("text")
    args = parser.parse_args()
    if args.command == "state":
        value = 0
        for name in args.buttons:
            value |= BUTTONS[name.upper()]
        send([packet(value, args.lx, args.ly, args.rx, args.ry, HATS[args.hat])],
             args.host, args.port)
    elif args.command == "tap":
        value = 0
        for name in args.buttons:
            value |= BUTTONS[name.upper()]
        send([packet(value)], args.host, args.port)
        time.sleep(max(0, args.ms) / 1000.0)
        send([packet(0)], args.host, args.port)
    else:
        send(text_packets(args.text), args.host, args.port, interval=2.0)


if __name__ == "__main__":
    main()
