#!/usr/bin/env python3
"""How this home is, for Luxeia's update server (the add-on's health report).

Every 30 minutes run.sh runs this. It reads, and only reads:
  - the Supervisor's own info (versions and updates, disk, backups, add-ons,
    and what it calls unhealthy), allowed by hassio_api with the default
    role, which can only read info;
  - Home Assistant's API (homeassistant_api): the integrations, and one
    template that counts offline devices by integration, low batteries,
    the Zigbee2MQTT bridge, remote access and the backup sensors.
Then it sends that to the update server (/v1/health), which decides what's a
problem (server/src/monitor.js), so the rules can change without an add-on
update. Report only: nothing here changes anything in the home. No names of
devices, rooms or people are sent, only counts by integration.

  health.py <update.conf> <add-on version>

The home key is read from update.conf and the Supervisor's token from
SUPERVISOR_TOKEN, never the command line. Prints the seconds until the next
report (the server's `every`, 600 to 21600; 1800 otherwise), and never fails
loudly: a home that can't report just tries again later.
LUXEIA_SUPERVISOR replaces http://supervisor, for tests.
"""
import json
import os
import re
import sys
import urllib.request

EVERY = 1800
SUPERVISOR = os.environ.get("LUXEIA_SUPERVISOR", "http://supervisor")
TOKEN = os.environ.get("SUPERVISOR_TOKEN", "")

# Rendered by Home Assistant. A device counts as offline only when none of
# its entities has a value (one unavailable sensor on a working plug
# doesn't); "unknown" says nothing either way. Its integration is the first
# of its identifiers.
TEMPLATE = r"""
{%- set ns = namespace(off=[], seen=[]) -%}
{%- for s in states if s.state == 'unavailable' -%}
  {%- set d = device_id(s.entity_id) -%}
  {%- if d and d not in ns.seen -%}
    {%- set ns.seen = ns.seen + [d] -%}
    {%- set alive = device_entities(d) | map('states') | reject('in', ['unavailable', 'unknown']) | list -%}
    {%- if alive | count == 0 -%}
      {%- set ids = device_attr(d, 'identifiers') | list -%}
      {%- set ns.off = ns.off + [(ids | first)[0] if ids else 'other'] -%}
    {%- endif -%}
  {%- endif -%}
{%- endfor -%}
{%- set batteries = states.sensor | selectattr('attributes.device_class', 'defined') | selectattr('attributes.device_class', 'eq', 'battery')
    | map(attribute='state') | select('is_number') | map('float') | select('lt', 15) | list -%}
{%- set z2m = states.binary_sensor | selectattr('entity_id', 'search', 'zigbee2mqtt_bridge_connection_state') | map(attribute='state') | list -%}
{{ {
  'offline': ns.off,
  'batteriesLow': batteries | count,
  'zigbee': z2m | first | default(none),
  'remote': states('binary_sensor.remote_ui') if states('binary_sensor.remote_ui') in ['on', 'off'] else none,
  'backupOk': states('sensor.backup_last_successful_automatic_backup'),
  'backupTried': states('sensor.backup_last_attempted_automatic_backup'),
} | tojson }}
"""

PROBLEM_STATES = {"setup_error", "setup_retry", "migration_error", "failed_unload"}


def call(path, data=None, timeout=20):
    """The Supervisor's (or, under /core/api, Home Assistant's) answer, or None"""
    req = urllib.request.Request(SUPERVISOR + path, data=None if data is None else json.dumps(data).encode(),
                                 headers={"Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as res:
            body = res.read(2_000_000).decode("utf-8", "replace")
    except Exception:
        return None
    if path.startswith("/core/api/template"):
        return body
    try:
        out = json.loads(body)
    except ValueError:
        return None
    # The Supervisor wraps its answers: {"result": "ok", "data": {...}}
    if isinstance(out, dict) and "result" in out and "data" in out:
        return out["data"] if out["result"] == "ok" else None
    return out


def version(info):
    if not isinstance(info, dict):
        return None
    out = {"version": str(info.get("version") or "")[:40]}
    if info.get("update_available") and info.get("version_latest"):
        out["latest"] = str(info["version_latest"])[:40]
    return out


def report(missing):
    def need(name, value):
        if value is None:
            missing.append(name)
        return value

    out = {}
    if not TOKEN:
        missing.append("everything (no access to Home Assistant)")
        return out
    for name in ("core", "os", "supervisor"):
        v = version(call("/%s/info" % name))
        # A home without Home Assistant OS has no /os/info: not a problem
        if v is None and name != "os":
            missing.append(name)
        if v:
            out[name] = v
    host = need("disk", call("/host/info"))
    if isinstance(host, dict) and host.get("disk_total"):
        out["disk"] = {"total": round(float(host["disk_total"]), 1), "used": round(float(host.get("disk_used") or 0), 1)}
    backups = need("backups", call("/backups/info"))
    if isinstance(backups, dict):
        dates = sorted((str(b.get("date") or "") for b in backups.get("backups") or [] if isinstance(b, dict)), reverse=True)
        out["backups"] = {"count": len(dates), "newest": dates[0] if dates else None, "staleDays": backups.get("days_until_stale")}
    sup = call("/supervisor/info")
    if isinstance(sup, dict):
        out["addons"] = [{"name": str(a.get("name") or "")[:60], "slug": str(a.get("slug") or "")[:60], "state": str(a.get("state") or "")[:20],
                          **({"update": True} if a.get("update_available") else {})}
                         for a in (sup.get("addons") or [])[:80] if isinstance(a, dict)]
    res = need("system checks", call("/resolution/info"))
    if isinstance(res, dict):
        out["resolution"] = {"unhealthy": [str(x)[:40] for x in res.get("unhealthy") or []][:10],
                             "unsupported": [str(x)[:40] for x in res.get("unsupported") or []][:10]}
    entries = need("integrations", call("/core/api/config/config_entries/entry"))
    flows = call("/core/api/config/config_entries/flow") or []
    if isinstance(entries, list):
        bad = [{"domain": str(e.get("domain") or "")[:40], "title": str(e.get("title") or "")[:60], "state": e.get("state")}
               for e in entries if isinstance(e, dict) and e.get("state") in PROBLEM_STATES and not e.get("disabled_by")]
        for f in flows if isinstance(flows, list) else []:
            ctx = (f.get("context") or {}) if isinstance(f, dict) else {}
            if ctx.get("source") == "reauth":
                name = (ctx.get("title_placeholders") or {}).get("name") or f.get("handler") or ""
                bad.append({"domain": str(f.get("handler") or "")[:40], "title": str(name)[:60], "state": "reauth"})
        out["integrations"] = bad[:40]
    text = need("devices", call("/core/api/template", {"template": TEMPLATE}, timeout=60))
    try:
        t = json.loads(text) if text else None
    except ValueError:
        t = None
        missing.append("devices (the template didn't work)")
    if isinstance(t, dict):
        offline = {}
        for domain in t.get("offline") or []:
            domain = re.sub(r"[^a-z0-9_]", "", str(domain).lower())[:40] or "other"
            offline[domain] = offline.get(domain, 0) + 1
        out["offline"] = offline
        out["batteriesLow"] = int(t.get("batteriesLow") or 0)
        for k in ("zigbee", "remote"):
            if t.get(k) in ("on", "off"):
                out[k] = t[k]
        when = lambda v: v if isinstance(v, str) and re.match(r"^\d{4}-\d{2}-\d{2}T", v) else None
        out["backupOk"], out["backupTried"] = when(t.get("backupOk")), when(t.get("backupTried"))
    return out


def conf(path):
    values = {}
    try:
        for line in open(path):
            k, _, v = line.partition("=")
            values[k.strip()] = v.strip().strip("\"'\r")
    except OSError:
        pass
    return values


def main():
    if len(sys.argv) < 3:
        print(EVERY)
        return
    c = conf(sys.argv[1])
    key = c.get("HOME_KEY", "")
    if not key:
        print(EVERY)
        return
    missing = []
    body = report(missing)
    body["addon"] = sys.argv[2][:20]
    if missing:
        body["missing"] = missing[:10]
    every = EVERY
    req = urllib.request.Request((c.get("SERVER") or "https://updates.luxeia.co.uk") + "/v1/health", data=json.dumps(body).encode(),
                                 headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as res:
            n = int(json.loads(res.read(10_000)).get("every") or EVERY)
            if 600 <= n <= 21600:
                every = n
    except Exception:
        pass
    print(every)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print(EVERY)
