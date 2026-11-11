# The wall tablet app's build keys

Public halves of the keys that sign the wall tablet app's builds (its own
repo, `LuxeiaLtd/luxeia-ha-tablet-dash`). The add-on installs a wall
tablet build only if it's signed with one of these, and the update server
accepts a wall tablet upload only if it's signed with one in its
`TABLET_BUILD_KEYS`. They're kept apart from `updater/keys/` (the phone
app's build keys) and `updater/display-keys/` (the touch displays'), so a
leaked wall tablet key can't sign another app's build, and the other way
round.

None yet: until the owner makes the key, homes install nothing for wall
tablets. Adding one (`luxeia-tablet-1.pem`): RELEASING.md › Wall tablets.
