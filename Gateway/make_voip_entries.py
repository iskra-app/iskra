"""Appends the two `.voip` app entries to an existing sygnal.yaml, reusing its key material.

Run on the gateway, against the live file, writing a candidate somewhere else::

    python3 make_voip_entries.py /opt/sygnal/sygnal.yaml ~/iskra-calls/sygnal.yaml

A text append rather than a YAML round-trip, and deliberately: the live file carries comments
explaining why there are two entries and what `topic` is, and PyYAML drops every one of them
without saying so. The key id and the team id are copied line for line from the entry that already
works, so nothing needs to know them — including whoever is running this.

Idempotent: a file that already has the entries is left alone.
"""

import re
import sys

source, destination = sys.argv[1], sys.argv[2]
text = open(source, encoding="utf-8").read()

if "wtf.iskra.voip" in text:
    print("ALREADY PRESENT — nothing to do")
    sys.exit(0)

# The production entry is the donor: same key, same team, same file on disk.
# `wtf.iskra` since the bundle ID moved; a gateway not yet moved still has `moscow.swag.iskra`,
# and its key and team are just as good — only the topic below is derived from the bundle ID.
block = (re.search(r"\n  wtf\.iskra:\n(.*?)(?=\n  \S|\n\S|\Z)", text, re.S)
         or re.search(r"\n  moscow\.swag\.iskra:\n(.*?)(?=\n  \S|\n\S|\Z)", text, re.S))
if not block:
    print("FAILED: could not find the wtf.iskra entry")
    sys.exit(1)

body = block.group(1)


def line(key: str) -> str:
    found = re.search(rf"^\s*{key}:\s*(.+?)\s*(?:#.*)?$", body, re.M)
    if not found:
        print(f"FAILED: no {key} in the existing entry")
        sys.exit(1)
    return found.group(1)


keyfile, key_id, team_id = line("keyfile"), line("key_id"), line("team_id")


def entry(name: str, platform: str) -> str:
    return f"""
  # Звонки. Отдельный app_id, потому что VoIP-пуш обязан приходить только на звонок: правила
  # пушей в Matrix не маршрутизируют по pusher'ам, и без фильтра сюда прилетало бы каждое
  # сообщение — а за VoIP-пуш без reportNewIncomingCall iOS отбирает право на VoIP.
  # Фильтрует RingPushkin по тегу, который вешает push-правило клиента. См. iskra_ring.py.
  {name}:
    type: iskra_ring.RingPushkin
    keyfile: {keyfile}
    key_id: {key_id}
    team_id: {team_id}
    topic: wtf.iskra.voip   # bundle id + ".voip" — это и есть весь VoIP-переключатель
    platform: {platform}
    push_type: voip
    convert_device_token_to_hex: false"""


text = (
    text.rstrip("\n")
    + "\n"
    + entry("wtf.iskra.voip.dev", "sandbox")
    + "\n"
    + entry("wtf.iskra.voip", "production")
    + "\n"
)
open(destination, "w", encoding="utf-8").write(text)
print("WROTE", destination)
