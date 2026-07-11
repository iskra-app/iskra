# Turning on shared storage

Iskra currently runs in `StorageMode.standalone`: the encrypted Matrix store and the
Keychain items live inside the app, and nothing else can see them. That is why the
app runs today without any provisioning.

It has to become `StorageMode.shared` before push notifications can work. A
notification service extension is a **separate process**; to decrypt a push on the
device it needs the same encrypted database and the same session as the app, and the
only way to hand it both is an App Group container (for the files) and a Keychain
access group (for the secrets).

This is the whole of what that takes.

## 1. Register the App Group

In the developer portal (Certificates, Identifiers & Profiles):

1. **Identifiers → App Groups →** register `group.moscow.swag.iskra`.
2. **Identifiers → App IDs →** make sure `moscow.swag.iskra` exists, enable the **App Groups**
   capability on it, and assign the group from step 1.

Or let Xcode do it: open `Apps/Iskra.xcodeproj`, select a target, **Signing &
Capabilities → + Capability → App Groups**, and tick the group. Xcode will register
both under team `936RH3UPR3` for you.

### Why one identifier and not two

`group.moscow.swag.iskra` is used as the App Group container **and** as the Keychain access
group. An App Group ID is already globally unique — that is what the mandatory
`group.` prefix buys — so it can serve as a Keychain access group directly, with no
`$(AppIdentifierPrefix)` team-ID prefix to get wrong.

It also papers over a real difference between the platforms: on iOS a group ID must
start with `group.`, while on macOS an *unregistered* one must start with the Team ID.
Registering it makes the same string legal on both, so the two platforms do not
diverge.

## 2. Add the entitlements

In `Apps/project.yml`, under the **iOS** target (it has no `entitlements:` block yet —
add one above `info:`):

```yaml
    entitlements:
      path: iOS/Iskra.entitlements
      properties:
        com.apple.security.application-groups: [group.moscow.swag.iskra]
        keychain-access-groups: [group.moscow.swag.iskra]
        aps-environment: development
```

And under the **macOS** target, alongside the sandbox keys it already has:

```yaml
        com.apple.security.application-groups: [group.moscow.swag.iskra]
        keychain-access-groups: [group.moscow.swag.iskra]
```

Then regenerate: `cd Apps && xcodegen`.

## 2a. Register the Mac as a device

A Mac App Development profile can only be issued for Macs registered to the team, and
this one is not. Either build the macOS target once from Xcode (it offers to register
the machine), or add it in the portal under **Devices**, platform macOS, with this
Mac's Provisioning UDID:

    00008132-001C398134B9001C

Until that happens the macOS target cannot be signed with these entitlements, and it
is the only thing standing between the Mac build and shared storage. iOS needs none of
this: the Simulator ignores provisioning entirely.

## 3. Flip the switch

In `Sources/IskraCore/Support/AppEnvironment.swift`:

Already done — `AppEnvironment.default` is `.shared`, pointing at
`group.moscow.swag.iskra`. `.standalone` is still there if provisioning ever needs to
be taken out of the picture while debugging something else.

## 4. Expect to sign in again

The switch moves both the store and the Keychain. The existing session lives in the
old location and will not be found, so the app will show the sign-in screen. There is
no migration, and for a messenger whose local state is a cache of the server's, that
is the honest trade rather than something to engineer around.

## Verifying it worked

`swift test` will not tell you. The tests run unsigned, and an unsigned binary cannot
open the data-protection Keychain at all — that is why secrets go through
`SecretStoring` and the tests inject an in-memory store. **Run the app.**

Signs it is right: the app reaches the sign-in screen, you sign in, and quitting and
relaunching keeps you signed in.

Signs it is wrong:

- **Crash on launch,** with `App Group "group.moscow.swag.iskra" is unavailable`. The
  entitlement is missing or the group is not registered. This crash is deliberate —
  see `AppEnvironment.containerURL`. Falling back to the app's own container instead
  would produce an app that works perfectly until the first push arrives and then
  fails a long way from the cause.
- **`No profiles for 'moscow.swag.iskra' were found`** at build time. Step 1 has not happened
  yet, or Xcode has not fetched the profile. Open the project in Xcode once, or build
  with `-allowProvisioningUpdates`. Note that this *writes to your developer account*:
  it registers the App ID and the group.
- **Sign-in fails with "Iskra couldn't set up secure storage on this device."** The
  App Group resolved but the Keychain access group did not — check that
  `keychain-access-groups` is in the entitlements too, not just the App Group.
