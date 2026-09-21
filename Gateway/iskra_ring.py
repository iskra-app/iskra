"""A Sygnal pushkin that sends a VoIP push for a ringing call, and for nothing else.

Why this file exists
--------------------

A ringing call on iOS has to arrive as a VoIP push: it is the only kind iOS wakes an app for in
time to ring. And since iOS 13 every delivered VoIP push must end in
``CXProvider.reportNewIncomingCall`` — miss it and the system first holds pushes back and then
stops delivering them to that app entirely, until it is reinstalled, with nothing logged anywhere.

So a VoIP push must be sent for calls and for nothing else. Matrix cannot arrange that on the
server: push rules do not route per pusher, so **every pusher on the account receives every
notification**, and the homeserver sends one ``/notify`` request with both of this app's devices
inside it. The only place that can send to one device and stay silent for the other is the gateway.

How it decides, and why it is the sound
---------------------------------------

Not by looking at the event. With ``format: event_id_only`` the gateway is sent a room id and an
event id and nothing else — deliberately, see ``docs/PUSH-GATEWAY.md`` — so there is no ``type`` to
branch on. The client therefore installs a push rule (``CallPushRule``) that marks a ring, and this
looks for the mark.

The mark is the **sound tweak**, and that is not the obvious choice. The obvious choice is a custom
tweak, which Matrix allows and Synapse forwards: ``set_tweak: moscow.swag.iskra.ring``. It cannot
work here, and the reason is in Sygnal rather than in Matrix::

    class Tweaks:
        def __init__(self, raw):
            self.sound = get_key(raw, "sound", str)

``Tweaks`` keeps ``sound`` and throws the rest away, and ``Notification`` does not keep the raw
payload either — every device is parsed into a ``Device`` before any pushkin is called. So a custom
tweak reaches the gateway process and is dropped inside it, one layer above this file, with no way
to reach down for it that does not involve monkeypatching Sygnal's parser.

``sound`` survives, is a string, and is app-defined. One bit, carried by the one field that gets
through.

The payload
-----------

PushKit hands the whole dictionary to the application; ``aps`` means nothing to it. The app's
``default_payload`` is shaped for an ordinary alert — it carries ``mutable-content`` and an
``alert`` with the server's fallback text — and none of that belongs on a VoIP push, where at best
it is ignored. It is removed here rather than in the app, so that everything about the shape of a
VoIP push lives in one file.

Installing it
-------------

The file has to be importable inside the Sygnal container. Nothing about the image changes; it is
one more volume and one environment variable::

    volumes:
      - ./pushkins:/pushkins:ro
    environment:
      PYTHONPATH: /pushkins

and then, in ``sygnal.yaml``::

    moscow.swag.iskra.voip.dev:
      type: iskra_ring.RingPushkin
      keyfile: /keys/AuthKey_XXXXXXXXXX.p8
      key_id: XXXXXXXXXX
      team_id: XXXXXXXXXX
      topic: moscow.swag.iskra.voip     # bundle id + ".voip"
      platform: sandbox
      push_type: voip
      convert_device_token_to_hex: false

plus the same entry named ``moscow.swag.iskra.voip`` with ``platform: production``.

A note on versions
------------------

``ApnsPushkin``'s internals are not a public API. The three things this rests on — the dispatch
hook, the payload builder for ``event_id_only``, and ``Tweaks.sound`` — are checked at import time
rather than assumed, so a Sygnal that has moved one of them fails loudly at startup. That is the
failure worth engineering for: a gateway that comes up and quietly rings nobody looks exactly like
a gateway that is working.
"""

import logging
from typing import List

from sygnal.apnspushkin import ApnsPushkin
from sygnal.notifications import Device, Notification, NotificationContext, Tweaks

logger = logging.getLogger(__name__)

#: The value the client's push rule puts in the sound tweak to mark a ring. Written down in two
#: places and nowhere else: here, and `CallPushRule.ringSound` in the app. There is no way to share
#: a constant between a Swift app and a Python module on somebody else's server.
RING_SOUND = "iskra.ring"


class RingPushkin(ApnsPushkin):
    """APNs, but only for calls, and with a payload PushKit can use."""

    def __init__(self, name, sygnal, config):
        super().__init__(name, sygnal, config)
        self._assert_hooks()

    @staticmethod
    def _assert_hooks() -> None:
        """Fail at startup rather than at three in the morning.

        Everything below rests on three things that belong to Sygnal rather than to us. If any has
        moved, the honest outcome is a container that refuses to start — not one that comes up and
        rings nobody.
        """
        missing = [
            name
            for name, owner in (
                ("_dispatch_notification_unlimited", ApnsPushkin),
                ("_get_payload_event_id_only", ApnsPushkin),
            )
            if not hasattr(owner, name)
        ]
        if not hasattr(Tweaks({}), "sound"):
            missing.append("Tweaks.sound")
        if missing:
            raise RuntimeError(
                "this Sygnal does not have %s; iskra_ring.RingPushkin needs updating for it"
                % ", ".join(missing)
            )

    @staticmethod
    def _is_ring(device: Device) -> bool:
        """Whether this notification is a call the client asked us to ring about."""
        return getattr(device.tweaks, "sound", None) == RING_SOUND

    async def _dispatch_notification_unlimited(
        self, n: Notification, device: Device, context: NotificationContext
    ) -> List[str]:
        """Send, or say nothing at all.

        Returning an empty list means "delivered, no pushkeys rejected" — which is what this app id
        wants for a message. Raising, or rejecting the pushkey, would make the homeserver retry or
        drop a pusher that is perfectly healthy.

        The *unlimited* hook rather than ``dispatch_notification``: the latter belongs to the
        concurrency-limiting base class, and overriding it would quietly take the limit off.
        """
        if not self._is_ring(device):
            # Deliberately not a warning. This is the ordinary case and it happens once per
            # message: the homeserver sends every notification to every pusher, and sorting them
            # out is the whole job of this class.
            logger.debug("not a ring — sending nothing for %s", self.name)
            return []

        logger.info("ringing: room=%s event=%s", n.room_id, n.event_id)
        return await super()._dispatch_notification_unlimited(n, device, context)

    def _get_payload_event_id_only(self, n: Notification) -> dict:
        """The room id and the event id, and nothing else.

        The app's ``default_payload`` is merged in by the base class and is shaped for a banner:
        ``mutable-content`` so the notification extension is woken, and an ``alert`` carrying the
        server's fallback words. A VoIP push is not a banner — PushKit gives the dictionary to the
        app and ``aps`` is never read — so it is dropped here.

        Dropped rather than never sent, because the same ``default_payload`` is registered for both
        pushers and the ordinary one genuinely needs it.
        """
        payload = super()._get_payload_event_id_only(n)
        payload.pop("aps", None)
        return payload
