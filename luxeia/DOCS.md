# Luxeia Home

The Luxeia dashboard, served only to people signed in to this home, and kept
up to date by Luxeia's update server.

- People don't have to find it: the Home Assistant app still opens on the
  home's usual Luxeia dashboard (the Webpage dashboard showing
  `/local/luxeia-dashboard/index.html`, set as the default), at home or away. With
  **Keep only the guest page public** on, that address holds a small
  opener page that takes them straight into the add-on, signed in as
  themselves. It also appears in the sidebar as **Luxeia Home**.
- Everyone signed in to the home can open it; nobody else can download it.
- Every night (at a random time between 2am and 5am) it asks Luxeia's
  update server for the build approved for this home. It installs it only
  if it carries both Luxeia's signatures, and keeps the previous build.
- Guest links keep working: with **Keep only the guest page public** on,
  `www/luxeia-dashboard` holds just the guest page and the opener.

## Installing it (once per home)

Home Assistant now calls add-ons **apps** (Settings › Apps, the App Store,
"Local apps"); older homes still say add-ons. Same thing.

1. **Add Luxeia's add-on store:** Settings › Apps › App Store › ⋮ ›
   **Repositories**, add `https://github.com/LuxeiaLtd/luxeia-ha-addon`
   and close.
2. **Install it:** Luxeia Home now appears in the store under Luxeia. Open
   it and press **Install**: the home builds it, which takes a few
   minutes. Leave **Auto update** off: Luxeia updates it when it chooses
   (RELEASING.md › The Luxeia add-on).
3. **Give it the home's set-up code:** the add-on's **Configuration** tab ›
   **Home key or set-up code**: the short code from Luxeia's update admin
   page (Homes › Add a home, or the home's Manage › Set-up code), like
   `ABCDE-23456` (capitals, spaces and the dash don't matter). Switch on
   **Keep only the guest page public**. Save. When it starts, the add-on
   swaps the code for the home's own key and keeps it (a full `lxh_` key
   works in the same box too).
4. **Start it**, and switch on **Watchdog** and **Show in sidebar** on its
   Info tab (the app also switches the watchdog on the first time an
   administrator opens it). You can hide the sidebar's Luxeia Home entry
   later if two entries look confusing.
5. **Make it open by itself:** a Webpage dashboard showing
   `/local/luxeia-dashboard/index.html` (with `index.html`: Home
   Assistant answers 403 for the folder on its own), set as the default. With **Keep only the
   guest page public** on, that address holds the opener, which goes
   straight on to the add-on. (Home Assistant can't make an add-on's own
   panel the screen the app opens on, so never remove this dashboard.)
6. **Check it:** in Luxeia Home, as an administrator, Settings › Home
   system › **Luxeia set-up** should tick everything; anything not ticked
   says what to do. Then on a phone, at home and on mobile data: the HA app
   opens straight into Luxeia Home, as someone who isn't an administrator too.
   The admin page shows the home's check-in. Then check that a guest link
   works, and that `/local/luxeia-dashboard/js/app.js` on the home's
   address says 404 (the dashboard itself isn't public).

**A home with the add-on copied in by hand** (`local_apps/luxeia`, before
the store): add the store and install Luxeia Home from it as above, with
the same home key and **Keep only the guest page public** on. Then stop
and **Uninstall** the old one (it shows under Local apps), start the new
one, and delete `local_apps/luxeia`. Its opener finds the new one by
itself (from add-on 1.1.1; a phone or browser that still says "Can't
reach Luxeia Home" after a move from 1.1.0 or earlier has kept the old
opener: clear it once, with the HA app's Settings › Companion app ›
Debugging › Reset frontend cache, or the browser's site data). The "Luxeia dashboard update check" automation isn't needed any
more (the app asks the add-on directly): delete it.

The add-on's log warns if the home still has the old nightly update from
before the add-on (`/config/scripts/check-update.sh`): remove its shell
command from `configuration.yaml`, the script and `/config/.luxeia/`, and
restart Home Assistant.

## Touch displays

For a home with Shelly Wall Displays, Luxeia marks it on the update
server, and Luxeia Home then fetches the touch display dashboard too, at
its next check. On each display, in the Shelly's own settings, set the
page it opens to `http://<this home's local address>:8123/local/luxeia-display/index.html`
and sign in once as the display's own user: it then opens Luxeia Home by
itself, without Home Assistant's dashboard underneath (which is too slow
on the smaller displays in a big home). If it can't open, the screen says
which step it was on, and Settings › System › Logs has a "luxeia.display"
line. Homes without displays get nothing extra.

## If something's wrong

The add-on's **Log** tab says what it did. Lines starting "Refused:" mean it
was offered something it won't install; it keeps the build it has (see
RELEASING.md › If something goes wrong).
