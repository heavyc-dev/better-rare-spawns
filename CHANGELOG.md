# Changelog

## 1.2.1

- The X on the alert card now closes it in combat too. Before, the card stayed until the fight was over.
  Right-clicking it in combat, or its timer running out, takes it out of sight at once.

## 1.2.0

Waypoints
- Tracking can be stopped: click the tracked map pin or list row again, or type `/brs untrack`. It also stops
  by itself when the tracked rare dies.
- With TomTom, a new waypoint replaces the previous one instead of adding another arrow, and stopping removes
  it. A map pin you placed yourself is no longer cleared.

Sharing
- A rare you only know from another player's report is treated as a guess until you see it yourself. If the
  creature turns out not to be a rare it is forgotten instead of alerting.
- Players with the same name on different realms are no longer mixed up (one of them could be taken for you).
- `/brs sync` and the login sync no longer ask the guild when guild sharing is turned off.

QuestieDB
- An import that fails no longer blocks `/brs import` until a reload.
- The import at login looks for QuestieDB a few more times when it is not ready yet.

Zone list and camp bar
- A rare reported from the next zone no longer shows that zone's coordinates as if they were in yours: its list
  row, hover card and waypoint now point at the right map.
- No more "spawns near here" notices while on a flight path.
- The camp bar closes when the rare it was waiting for turns out not to be one.

Other
- Learning a rare or a spawn point updates that one rare instead of rebuilding the whole list.
- Settings saved by the very first versions are migrated like any other.

## 1.1.1

- The camp bar no longer pops up by itself at spawn points. Turn it back on in the options, or open it any time
  with `/brs camp`.

## 1.1.0

Fixes from a full review of the addon.

Sharing
- Messages from other players are checked much more strictly: whole numbers only, real layer ids, no UI escape
  codes in rare names. Whispers are ignored, and timer sync requests are only answered in the guild.
- Other players can no longer flood you: each sender is rate limited and can teach at most a few new rares per
  session, and only when "learn new rares" is on.
- Guild sync now shares learned spawn windows as windows. They are used until you measure your own, and no
  longer wear down real measurements.
- Live sightings go out before sync traffic. Group sharing works in dungeon finder and LFR groups.
- `/brs sync` tells you when receiving is turned off.

Timers
- A rare seen on another layer no longer hides the death timer on your layer.
- A sighting that arrives just after a kill no longer shows the rare as up again.
- Looking at or looting a corpse again no longer moves the death time later.
- Old layer data is cleaned up automatically.
- Spawn-window notices no longer fire falsely after changing layers or turning notices back on.

Detection
- Skinning, mining, herb gathering, pick pocketing and fishing no longer count as a kill or a drop. Drops count
  once per corpse.
- Spawn points are only learned when the rare is close, not from a distant nameplate.
- Rares found only through a map vignette stay unconfirmed and are not shared until you see one.
- Death yells no longer count as sightings.
- The scan key and alert card use the name as your client spells it on non-English clients.

Map, minimap and windows
- Continent map pins are placed correctly for fresh sightings and show each rare once.
- Only the tracked waypoint sits on the minimap edge.
- Smoother zooming on busy maps, and pins created in combat still let right-click zoom out.
- `/brs camp` from further away no longer closes after a few seconds, and camping works in caves and towns.
- The journal's Wanted checkbox no longer covers the All rares tab, and the drop search no longer floods the
  server with item requests.
- Hover cards follow the row under the cursor, and the map no longer closes cards opened by other windows.
- Options "Defaults" now hides the tracker and resets the minimap button position.

## 1.0.0

First public release.

- Alerts with a click-to-target card when a rare is found by nameplate, mouseover, target, scan key, yell or a
  report from guild or group.
- Respawn timers learned from what you witness, shown as spawn windows.
- World map and minimap pins coloured by timer state, one pin per rare with the rest on hover, and minimap pins
  across zone borders.
- Rare journal in the spellbook frame: search and filter by name, zone, level, drop or pet family, with each
  rare's drops, quests and spawn points.
- Kill log, wanted list, camp bar, spawn-window notices, announce button and guild timer sync.
- Scan key that targets any rare near you, bindable from the options window.
- Minimap button with a data broker feed, and a setup check at first login.
