"""Checks iskra_ring against stubs standing in for Sygnal, without Sygnal and without Docker.

    python3 Gateway/check_pushkin.py Gateway

Two signatures are exercised on purpose. Upstream's main branch has
``_get_payload_event_id_only(self, n, default_payload)``; the Sygnal actually deployed on the
gateway has ``(self, n, default_payload, send_badge_counts)``. The pushkin must fit both, because
pinning it to either is how it broke — once by being written for a shape that was already out of
date, and once by refusing to start against a shape that was newer than upstream.

What is checked:

1. the hook names exist and a ring can still be marked (`_assert_hooks` passes);
2. a *removed* hook is still caught, because that one genuinely breaks the class;
3. the payload passes through both signatures untouched;
4. ``aps`` is gone from the VoIP payload and the identifiers PushKit needs are not;
5. only a marked ring counts as a ring.
"""

import sys
import types
from typing import Any, Dict, List, Optional

# --- stubs ------------------------------------------------------------------------------------

notifications = types.ModuleType("sygnal.notifications")


class Tweaks:
    def __init__(self, raw: Dict[str, Any]):
        self.sound: Optional[str] = raw.get("sound")


class Device:
    def __init__(self, raw: Dict[str, Any]):
        self.app_id = raw["app_id"]
        self.pushkey = raw["pushkey"]
        self.data = raw.get("data")
        self.tweaks = Tweaks(raw.get("tweaks", {}))


class Notification:
    def __init__(self, raw: Dict[str, Any]):
        self.room_id = raw.get("room_id")
        self.event_id = raw.get("event_id")


class NotificationContext:
    pass


notifications.Tweaks = Tweaks
notifications.Device = Device
notifications.Notification = Notification
notifications.NotificationContext = NotificationContext

apnspushkin = types.ModuleType("sygnal.apnspushkin")


class ApnsPushkin:
    """Upstream main: three parameters."""

    def __init__(self, name: str, sygnal: Any, config: Any):
        self.name = name

    async def _dispatch_notification_unlimited(
        self, n: Notification, device: Device, context: NotificationContext
    ) -> List[str]:
        return ["sent"]

    def _get_payload_event_id_only(
        self, n: Notification, default_payload: Dict[str, Any]
    ) -> Dict[str, Any]:
        payload = dict(default_payload)
        payload["room_id"] = n.room_id
        payload["event_id"] = n.event_id
        return payload


class DeployedApnsPushkin(ApnsPushkin):
    """The one on the gateway: four, with `send_badge_counts`."""

    def _get_payload_event_id_only(
        self, n: Notification, default_payload: Dict[str, Any], send_badge_counts: bool = False
    ) -> Dict[str, Any]:
        payload = dict(default_payload)
        payload["room_id"] = n.room_id
        payload["event_id"] = n.event_id
        if send_badge_counts:
            payload["unread_count"] = 1
        return payload


apnspushkin.ApnsPushkin = ApnsPushkin

sys.modules["sygnal"] = types.ModuleType("sygnal")
sys.modules["sygnal.notifications"] = notifications
sys.modules["sygnal.apnspushkin"] = apnspushkin

sys.path.insert(0, sys.argv[1])
import iskra_ring  # noqa: E402

failures: List[str] = []
BANNER = {"aps": {"mutable-content": 1, "alert": {"title": "Iskra", "body": "Новое сообщение"}}}


def check(condition: bool, good: str, bad: str) -> None:
    if condition:
        print(f"✅ {good}")
    else:
        failures.append(bad)
        print(f"❌ {bad}")


# --- 1. the hooks are there --------------------------------------------------------------------

try:
    iskra_ring.RingPushkin._assert_hooks()
    check(True, "_assert_hooks passes", "")
except RuntimeError as error:
    check(False, "", f"_assert_hooks rejected a Sygnal it should accept: {error}")

# --- 2. a removed hook is caught ---------------------------------------------------------------

saved = ApnsPushkin._get_payload_event_id_only
del ApnsPushkin._get_payload_event_id_only
try:
    iskra_ring.RingPushkin._assert_hooks()
    check(False, "", "a missing hook was not noticed — the check is worthless")
except RuntimeError as error:
    check(True, f"a missing hook is caught: {error}", "")
finally:
    ApnsPushkin._get_payload_event_id_only = saved

# --- 3 & 4. the payload survives both signatures, minus `aps` ----------------------------------

for label, base in (("upstream main (3 args)", ApnsPushkin),
                    ("the deployed Sygnal (4 args)", DeployedApnsPushkin)):
    # Re-parent RingPushkin itself. A subclass of it with its bases swapped would stop inheriting
    # the very override under test — which this got wrong once, and the test dutifully reported
    # the pushkin as broken when the pushkin was fine.
    iskra_ring.RingPushkin.__bases__ = (base,)
    pushkin = iskra_ring.RingPushkin.__new__(iskra_ring.RingPushkin)
    pushkin.name = "wtf.iskra.voip.dev"

    note = Notification({"room_id": "!r:example.org", "event_id": "$e"})
    try:
        payload = pushkin._get_payload_event_id_only(note, BANNER)
    except TypeError as error:
        check(False, "", f"{label}: the override does not fit — {error}")
        continue

    check("aps" not in payload,
          f"{label}: aps is gone",
          f"{label}: aps survived into the VoIP payload")
    check(payload.get("room_id") == "!r:example.org" and payload.get("event_id") == "$e",
          f"{label}: room_id and event_id are there — {payload}",
          f"{label}: PushKit would get no identifiers — {payload}")

iskra_ring.RingPushkin.__bases__ = (ApnsPushkin,)

# --- 5. the filter ------------------------------------------------------------------------------

marked = Device({"app_id": "x", "pushkey": "y", "tweaks": {"sound": iskra_ring.RING_SOUND}})
plain = Device({"app_id": "x", "pushkey": "y", "tweaks": {}})
other = Device({"app_id": "x", "pushkey": "y", "tweaks": {"sound": "default"}})

check(iskra_ring.RingPushkin._is_ring(marked),
      "a marked ring is recognised", "a marked ring was not recognised")
check(not iskra_ring.RingPushkin._is_ring(plain) and not iskra_ring.RingPushkin._is_ring(other),
      "an ordinary message is not a ring", "something that is not a ring was treated as one")

print()
if failures:
    print(f"{len(failures)} проблем(ы)")
    sys.exit(1)
print("all good")
