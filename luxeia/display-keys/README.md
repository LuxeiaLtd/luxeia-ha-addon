# The touch display app's build keys

Public halves of the keys that sign the touch display app's builds (its
own repo, for Shelly Wall Displays). The add-on installs a display build
only if it's signed with one of these, and the update server accepts a
display upload only if it's signed with one in its `DISPLAY_BUILD_KEYS`.
They're kept apart from `updater/keys/` (the phone app's build keys), so a
leaked display key can't sign a phone build, and the other way round.

`luxeia-display-1.pem` is the live key (October 2026): its private half
is the `LUXEIA_BUILD_KEY` secret of the touch display repo's `release`
environment, and the owner's password manager. Adding or replacing one:
RELEASING.md › Touch displays.
