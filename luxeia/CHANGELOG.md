# Changelog

## 1.4.2

- Touch displays can open Luxeia Home on their own: set the display to
  open /local/luxeia-display/index.html, sign in once, and it connects by
  itself, without Home Assistant's dashboard underneath (too slow on the
  4-inch display in a big home).
- Opening Luxeia Home gives up on a step that doesn't answer within 15
  seconds (it used to wait minutes), says which step it's on, and when it
  can't, says why in small print and in Home Assistant's log.

## 1.4.1

- Trusts the touch display dashboard's own signing key, so homes with
  touch displays can install it once a build is approved.

## 1.4.0

- Ready for Shelly Wall Displays: for a home with touch displays set up on
  Luxeia's admin page, it also fetches the touch display dashboard (signed
  with its own key, approved separately) and shows it at
  /local/luxeia-display/index.html for the displays' dashboard. Homes
  without displays are unchanged.

## 1.3.1

- Writing how its last check went can no longer get in the way of a new
  dashboard being swapped in at the same moment.

## 1.3.0

- A new home can be set up with a short set-up code from Luxeia's admin
  page (like ABCDE-23456) instead of copying a long key: type it into
  "Home key or set-up code" and the add-on swaps it for the home's key.
- Tells the Luxeia app how it's set up, for its set-up check in Settings ›
  Home system.

## 1.2.0

- Test homes check for an approved build every 15 minutes, so a build
  approved for them arrives within minutes; other homes still check once
  a night.
- Reports its own version to Luxeia's update server, so the admin page
  shows which homes still need the add-on's Update.

## 1.1.1

- The page the app opens on now fetches its instructions fresh every
  time, so a phone's saved copy can never keep looking for Luxeia Home in
  the wrong place (it tries every place Luxeia Home can be installed from).

## 1.1.0

- Installs from Luxeia's add-on store, so new versions appear here as an
  Update button.
- "Check for updates" in the app asks the add-on itself: no update
  automation is needed any more.
- The opener finds this add-on wherever it was installed from.

## 1.0.2

- A new web server that lets phones keep the app's files until the next
  update, so it opens in a second or two away from home.

## 1.0.1

- Updates only from Luxeia's update server (the GitHub route is gone).

## 1.0.0

- First version: serves the dashboard behind Home Assistant's sign-in,
  updates it with Luxeia's signed and approved builds, and keeps only the
  guest page public.
