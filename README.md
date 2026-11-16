# BetterRareSpawns

A rare spawn tracker for World of Warcraft (built and tested against the `wowf` client, Interface 16001).
No libraries, about 100 KB.

## What it does

- **Finds rares** from nameplates, mouseover, target, minimap vignettes and monster yells. Anything the
  client classifies as rare or rare elite is learned on sight, so it works with no database at all.
- **Scan key** (Key Bindings > AddOns): one key that tries to target every rare near you. Uses no macro
  slot. The list follows you as you move and puts the most likely rares first.
- **Respawn timers** learned from what you witness (death, then the next spawn), kept per layer.
- **World map pins** coloured by state: up, window open, overdue, dead, unknown. Pins that would overlap
  merge into one counted pin and split when you zoom in. Continent maps show only rares worth the trip.
- **Hover card** next to the pin: instant, never under the cursor, timers count live, and stacked pins
  list every rare in one card.
- **Minimap dots**, with the tracked rare pinned to the rim when it is out of range.
- **Rare list** (`/brs`) for the current zone, most promising first.
- **Sharing** of sightings, deaths and respawn times with guild and group over hidden addon messages.

## Controls

| Where | Action | Result |
| --- | --- | --- |
| Map pin, list row | Click | Waypoint and track |
| | Shift-click | Put name, coordinates and status in the chat box |
| | Alt-click | Hide that rare (`/brs unhide` to undo) |
| Map pin | Right-click | Zooms the map out, as usual |
| Alert card | Click / right-click | Target the rare / dismiss |

`/brs help` lists the commands.

## Data

The addon ships no rare database. Rares come from:

1. what you see in the world (always), and
2. the [QuestieDB](https://github.com/Questie/QuestieDB) addon, if you have it installed. Its rare and
   rare elite NPCs are read at runtime and cached in your own saved variables. Nothing from it is
   redistributed here.

## Development

```
pip install lupa
python tests/run.py
```

The tests load the addon in Lua 5.1 against a stubbed game API (`tests/wowstub.lua`) and drive it through
events. They check logic, not rendering: anything visual still needs a look in the game.

---

Artificial intelligence tools may have been used to assist with data organization, drafting, or analysis. Recommendations, conclusions, and advice are reviewed by a qualified professional and should not be attributed to any automated system. Our firm maintains records in accordance with SEC books and records requirements. Our firm takes measures to ensure client information is safeguarded.
