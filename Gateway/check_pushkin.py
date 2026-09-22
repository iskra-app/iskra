"""Checks iskra_ring against stubs that carry Sygnal's real signatures.

The point is narrow: prove that `_assert_hooks` passes for the Sygnal we are actually deploying
against, and *fails* when a signature moves — which is the bug that just shipped. The stubs are
copied from matrix-org/sygnal main, not invented.
"""
import sys
import types
from typing import Any, Dict, List, Optional

# --- stubs, with signatures copied verbatim from Sygnal ---------------------------------------

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
    def __init__(self, name, sygnal, config):
        self.name = name

    async def _dispatch_notification_unlimited(
        self, n: Notification, device: Device, context: NotificationContext
    ) -> List[str]:
        return ["sent"]

    def _get_payload_event_id_only(
        self, n: Notification, default_payload: Dict[str, Any]
    ) -> Dict[str, Any]:
        payload = {}
        payload.update(default_payload)
        payload["room_id"] = n.room_id
        payload["event_id"] = n.event_id
        return payload


apnspushkin.ApnsPushkin = ApnsPushkin

sygnal_pkg = types.ModuleType("sygnal")
sys.modules["sygnal"] = sygnal_pkg
sys.modules["sygnal.notifications"] = notifications
sys.modules["sygnal.apnspushkin"] = apnspushkin

sys.path.insert(0, sys.argv[1])
import iskra_ring  # noqa: E402

failures = []

# --- 1. the hooks fit the Sygnal we deploy against --------------------------------------------

try:
    iskra_ring.RingPushkin._assert_hooks()
    print("✅ _assert_hooks passes against Sygnal's real signatures")
except RuntimeError as error:
    failures.append(f"_assert_hooks rejected a Sygnal it should accept: {error}")

# --- 2. and it notices when one moves ---------------------------------------------------------


def _moved(self, n):  # the old, one-argument shape — exactly the bug that shipped
    return {}


ApnsPushkin._get_payload_event_id_only = _moved
try:
    iskra_ring.RingPushkin._assert_hooks()
    failures.append("_assert_hooks accepted a moved signature — the check is worthless")
except RuntimeError as error:
    print(f"✅ a moved signature is caught: {error}")
finally:
    ApnsPushkin._get_payload_event_id_only = (
        apnspushkin.ApnsPushkin.__dict__["_get_payload_event_id_only"]
    )

# --- 3. the payload really loses `aps`, and keeps the identifiers ------------------------------


class _Restored(ApnsPushkin):
    def _get_payload_event_id_only(self, n, default_payload):
        payload = {}
        payload.update(default_payload)
        payload["room_id"] = n.room_id
        payload["event_id"] = n.event_id
        return payload


iskra_ring.RingPushkin.__bases__ = (_Restored,)

pushkin = iskra_ring.RingPushkin.__new__(iskra_ring.RingPushkin)
pushkin.name = "moscow.swag.iskra.voip.dev"

default_payload = {
    "aps": {"mutable-content": 1, "alert": {"title": "Iskra", "body": "Новое сообщение"}}
}
payload = pushkin._get_payload_event_id_only(
    Notification({"room_id": "!r:example.org", "event_id": "$e"}), default_payload
)

if "aps" in payload:
    failures.append("aps survived into the VoIP payload")
elif payload.get("room_id") != "!r:example.org" or payload.get("event_id") != "$e":
    failures.append(f"the identifiers PushKit needs are missing: {payload}")
else:
    print(f"✅ VoIP payload is {payload} — no aps, both identifiers present")

# --- 4. the filter itself ----------------------------------------------------------------------

ring = Device({"app_id": "x", "pushkey": "y", "tweaks": {"sound": iskra_ring.RING_SOUND}})
message = Device({"app_id": "x", "pushkey": "y", "tweaks": {}})
other = Device({"app_id": "x", "pushkey": "y", "tweaks": {"sound": "default"}})

if not iskra_ring.RingPushkin._is_ring(ring):
    failures.append("a marked ring was not recognised")
elif iskra_ring.RingPushkin._is_ring(message) or iskra_ring.RingPushkin._is_ring(other):
    failures.append("something that is not a ring was treated as one")
else:
    print("✅ only a ring is a ring")

print()
if failures:
    for failure in failures:
        print(f"❌ {failure}")
    sys.exit(1)
print("all good")
