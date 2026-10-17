# Contributing to Iskra

Thank you for wanting to help. Two things come before any code: the licence you
contribute under, and how you say yes to it.

## The licence, and the one thing it adds

Iskra is GPL-3.0 **with an additional permission** that lets it be published through
app stores — [`LICENSE-EXCEPTION.md`](LICENSE-EXCEPTION.md). The GPL on its own conflicts
with App Store terms, and the author of every line in the app has to allow it to ship
there. Without that, one contribution under the plain GPL would be enough to keep the app
out of the store for good.

So a contribution is accepted only under **the GPL-3.0 with that permission included**.
The bridge is not here: it lives in
[`iskra-app/iskra-bridge`](https://github.com/iskra-app/iskra-bridge), under MIT.

## How you agree: sign off every commit

Commit with `-s`:

```sh
git commit -s -m "…"
```

which adds a line with your name and email to the end of the message:

```
Signed-off-by: Your Name <you@example.com>
```

In this project that line means:

> I wrote this change, or otherwise have the right to submit it, and I agree that it is
> distributed under the GNU GPL version 3 together with the additional permission in
> `LICENSE-EXCEPTION.md` — including through app stores.

That is the [Developer Certificate of Origin](https://developercertificate.org) plus one
sentence about the stores. It lives in the commit itself, so it survives a rebase, a
mirror and a move away from GitHub, which a checkbox in a pull request would not. A pull
request with commits that are not signed off is not merged.

A GitHub noreply address in the sign-off is fine:
`git config user.email "<id>+<login>@users.noreply.github.com"`.

## Before you open a pull request

- **Read [`CLAUDE.md`](CLAUDE.md).** Despite its name it is the project's working guide:
  how the targets depend on each other, what the bridge must never do, and the
  invariants that fail quietly and far from their cause.
- **`swift test` passes**, and anything that touches a screen has been looked at on
  iPhone and on the Mac — the demo server (`--mock-backend`) gives every screen
  something to show.
- **No user-facing string in a view.** Words go into
  `Resources/<lang>.lproj/Localizable.strings` in all seven languages. Write the Russian
  first, then the English: a sentence composed in English and translated loses the plain
  voice the app speaks in. If you cannot translate, put the English in as a placeholder
  and say so in the pull request.
- **No code from [element-x-ios](https://github.com/element-hq/element-x-ios).** It is
  AGPL-3.0 and the copyright is Element's. Reading it as a reference is fine; copying
  from it is not.
- **No cryptography of your own.** Matrix cryptography is the Rust SDK's, and stays so.
- **Nothing in a log** that is a message, a token, a password or an OAuth callback URL.

## Reporting a vulnerability

Please do not open a public issue. Use **Security → Report a vulnerability** on GitHub,
which reaches the maintainer privately.
