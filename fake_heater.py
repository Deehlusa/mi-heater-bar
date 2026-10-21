#!/usr/bin/env python3
"""Fake miIO heater on 127.0.0.1:54321 for end-to-end tests."""
import argparse
import hashlib
import json
import socket
import struct
import time

from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

TOKEN = bytes.fromhex("00112233445566778899aabbccddeeff")
DID = 0x0A1B2C3D

# (siid, piid) -> [value, writable, range]
MODELS = {
    "zhimi.heater.mc2a": {
        (2, 1): [True, True, None],
        (2, 2): [0, False, None],
        (2, 5): [20.0, True, (18, 28)],
        (4, 7): [19.5, False, None],
    },
    "zhimi.heater.ma5": {
        (2, 1): [True, True, None],
        (2, 5): [20.0, True, (16, 28)],
        (2, 6): [21.0, False, None],
        (2, 7): [0, True, (0, 2)],
        (4, 7): [19.0, False, None],
    },
    "leshow.heater.nfj3lx": {
        (2, 1): [False, True, None],
        (2, 2): [0, False, None],
        (2, 3): [24, True, (22, 28)],
        (2, 5): [0, True, (0, 3)],
        (3, 1): [0, True, (0, 480)],
        (4, 7): [19, False, None],
        (8, 1): [False, True, None],
    },
}


# Mimic firmwares that ack set_properties on these props but ignore the value.
IGNORED_SETS = {"leshow.heater.nfj3lx": {(2, 1)}}
# (siid, aiid) -> boolean prop the action toggles.
TOGGLE_ACTIONS = {"leshow.heater.nfj3lx": {(2, 1): (2, 1)}}


def md5(b):
    return hashlib.md5(b).digest()


def _cipher(token):
    key = md5(token)
    return Cipher(algorithms.AES(key), modes.CBC(md5(key + token)))


def encrypt(plain, token):
    padder = padding.PKCS7(128).padder()
    enc = _cipher(token).encryptor()
    return enc.update(padder.update(plain) + padder.finalize()) + enc.finalize()


def decrypt(data, token):
    dec = _cipher(token).decryptor()
    unpadder = padding.PKCS7(128).unpadder()
    return unpadder.update(dec.update(data) + dec.finalize()) + unpadder.finalize()


def encode(payload, token, did, stamp):
    body = encrypt(payload, token)
    header = struct.pack(">HHIII", 0x2131, 32 + len(body), 0, did, stamp)
    return header + md5(header + token + body) + body


def decode(packet, token):
    magic, length, _, did, stamp = struct.unpack(">HHIII", packet[:16])
    assert magic == 0x2131 and length == len(packet), "bad header"
    body = packet[32:]
    assert md5(packet[:16] + token + body) == packet[16:32], "bad checksum"
    return did, stamp, decrypt(body, token)


def handle(req, props, model):
    method, params = req["method"], req.get("params", [])
    if method == "miIO.info":
        return {"model": model, "fw_ver": "fake", "hw_ver": "fake"}
    if method == "get_properties":
        out = []
        for p in params:
            key = (p["siid"], p["piid"])
            item = {"did": p["did"], "siid": key[0], "piid": key[1]}
            if key in props:
                item.update(code=0, value=props[key][0])
            else:
                item["code"] = -4003
            out.append(item)
        return out
    if method == "set_properties":
        out = []
        for p in params:
            key = (p["siid"], p["piid"])
            entry = props.get(key)
            code = 0
            if entry is None or not entry[1]:
                code = -4003
            elif entry[2] and not entry[2][0] <= p["value"] <= entry[2][1]:
                code = -4005
            elif key not in IGNORED_SETS.get(model, set()):
                entry[0] = p["value"]
            out.append({"did": p["did"], "siid": key[0], "piid": key[1], "code": code})
        return out
    if method == "action":
        prop = TOGGLE_ACTIONS.get(model, {}).get((params["siid"], params["aiid"]))
        if prop is None:
            return {"did": params["did"], "siid": params["siid"], "aiid": params["aiid"], "code": -4004}
        props[prop][0] = not props[prop][0]
        return {"did": params["did"], "siid": params["siid"], "aiid": params["aiid"], "code": 0}
    raise KeyError(method)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True, choices=sorted(MODELS))
    args = ap.parse_args()
    props = {k: list(v) for k, v in MODELS[args.model].items()}
    start = time.time()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("127.0.0.1", 54321))
    print(f"fake heater {args.model} listening", flush=True)
    while True:
        packet, addr = sock.recvfrom(4096)
        stamp = 1000 + int(time.time() - start)
        if len(packet) == 32 and packet[4:] == b"\xff" * 28:
            sock.sendto(struct.pack(">HHIII", 0x2131, 32, 0, DID, stamp) + b"\xff" * 16, addr)
            continue
        try:
            _, _, plain = decode(packet, TOKEN)
            req = json.loads(plain)
            try:
                resp = {"id": req["id"], "result": handle(req, props, args.model)}
            except KeyError:
                resp = {"id": req["id"], "error": {"code": -32601, "message": "Method not found"}}
        except Exception as e:  # malformed packet: no reply, like a real device
            print(f"drop: {e}", flush=True)
            continue
        print(f"{req['method']} {json.dumps(req.get('params'))} -> {json.dumps(resp)}", flush=True)
        # Real devices often pad the JSON with a trailing NUL.
        sock.sendto(encode(json.dumps(resp).encode() + b"\x00", TOKEN, DID, stamp), addr)


if __name__ == "__main__":
    main()
