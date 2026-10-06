# Brainrot Tower Build Spec

This document explains how to lay out the `Workspace.Bases.BaseN` models in
Roblox Studio so they work with the tier-driven `PlotService` /
`BaseUpgradeService`. The runtime code lives in
`src/server/Services/PlotService.luau` and the tier table that drives all of
this is in `src/shared/Config/PlotConfig.luau`.

## High-Level Concept

Each player owns one tower. The tower has 6 floors stacked vertically. The
player starts at Tier 1 (only Floor1 visible) and unlocks each subsequent
floor by spending rebirths and money at an `UpgradePad` at the back of the
current floor. Each floor above the lobby is reached by climbing a `Ladder`
(`TrussPart`) that runs up through a hole in the back of every upper-floor
slab. The ladder for FloorN lives inside FloorN, so it stays hidden (along
with the rest of FloorN) until the player has unlocked that tier.

## Tier Ladder (from `PlotConfig.TIERS`)

| Tier | Floor  | Display Name      | Rebirths | Money       | New Slots | Cumulative |
| ---- | ------ | ----------------- | -------- | ----------- | --------- | ---------- |
| 1    | Floor1 | Espresso Lobby    | 0        | $0 (free)   | 10        | 10         |
| 2    | Floor2 | Mezzanine Studio  | 1        | $5,000      | 4         | 14         |
| 3    | Floor3 | Glass Penthouse   | 3        | $50,000     | 4         | 18         |
| 4    | Floor4 | Sky Lounge        | 5        | $500,000    | 4         | 22         |
| 5    | Floor5 | Helipad Suite     | 8        | $5,000,000  | 4         | 26         |
| 6    | Floor6 | Sky Vault         | 12       | $50,000,000 | 6         | 32         |

Costs and counts can be retuned in `PlotConfig.TIERS` without touching
build assets, as long as `slotsOnThisFloor` matches the number of `PadGroup`
children inside each `FloorN` model.

## Required Per-Base Hierarchy

Each `Workspace.Bases.BaseN` (`Base1` through `Base6`) must look like this:

```
BaseN/                                        (Model)
  SpawnLocation                               (BasePart, named exactly "SpawnLocation")
  Floor1/                                     (Model or Folder, named exactly "Floor1")
    PadGroup1/                                (Model)
      Pad                                     (BasePart - the place button)
      Collect                                 (BasePart - the collect button)
      DisplayPoint                            (BasePart - where the brainrot model spawns;
                                               can also be omitted, in which case Pad
                                               doubles as the display point)
    PadGroup2/  ... PadGroup10/               (10 PadGroups total on Floor1)
    UpgradePad                                (BasePart at the back of the floor)
    Decor models...                           (anything else - lights, walls, props)
                                               (no Ladder here - Floor1 is the entry
                                               floor; the climb up to FloorN lives
                                               inside FloorN, see below)
  Floor2/
    FloorSlab                                 (BasePart - main slab; should leave a
                                               back-edge gap for the Ladder to pass
                                               through. Build it as 1 large front part
                                               plus optional back-left/back-right parts
                                               around the hole.)
    Ladder                                    (TrussPart - climbable, runs from the
                                               surface of Floor1 up to ~0.5 stud above
                                               the surface of Floor2, positioned in the
                                               back-edge slab gap)
    PadGroup1/  ... PadGroup4/                (4 PadGroups)
    UpgradePad                                (BasePart at the back of the floor)
    Decor models...
  Floor3/  FloorSlab + Ladder + PadGroup1..4 + UpgradePad + decor
  Floor4/  FloorSlab + Ladder + PadGroup1..4 + UpgradePad + decor
  Floor5/  FloorSlab + Ladder + PadGroup1..4 + UpgradePad + decor
  Floor6/  FloorSlab + Ladder + PadGroup1..6 + decor   (no UpgradePad - max tier)
```

### Naming Rules

- Floor containers MUST be named `Floor1`, `Floor2`, ..., `Floor6` exactly.
- PadGroups MUST be named either `PadGroup` or `PadGroupN` (`PadGroup1`,
  `PadGroup2`, ...). Numbering can restart per floor — slot indices are
  derived from the cumulative tier ranges, not from PadGroup names.
- Inside each PadGroup, the parts must be named exactly `Pad`, `Collect`,
  and `DisplayPoint`.
- The upgrade button must be named exactly `UpgradePad` and live as a direct
  child of its `FloorN` container.
- The climbable column (if present) should be a `TrussPart` named exactly
  `Ladder`, parented to the `FloorN` it leads UP TO (so e.g. the ladder from
  Floor1→Floor2 lives inside `Floor2`). This is what gates climbing on tier:
  the runtime auto-hides FloorN (including the Ladder) until tier N is
  unlocked.

### Slot-Index Math

The runtime assigns slots in tier order and always starts each floor at the
first unused slot:

- Floor1 owns global slots 1..10
- Floor2 owns global slots 11..14
- Floor3 owns global slots 15..18
- Floor4 owns global slots 19..22
- Floor5 owns global slots 23..26
- Floor6 owns global slots 27..32

Within a floor, PadGroups are sorted alphabetically by name and assigned the
next slot indices in that order. So put the alphabetic order you want on the
in-floor pads (`PadGroup1`, `PadGroup2`, ...).

## Visual Theme Per Floor

A starting point — feel free to riff inside each floor as long as you don't
rename the structural children listed above.

- **Floor1 / Espresso Lobby** — marble/brass, espresso bar reception desk,
  faint cyan neon "Brainrot Inc." sign, Italian flag accent rug. Cyan trim
  (`Color3.fromRGB(0, 200, 255)`).
- **Floor2 / Mezzanine Studio** — exposed brick, warm pendant lights, record
  player. Purple trim (`Color3.fromRGB(180, 90, 255)`).
- **Floor3 / Glass Penthouse** — floor-to-ceiling windows, plush sectional
  couch, brainrot trophy shelf. Magenta trim
  (`Color3.fromRGB(255, 60, 200)`).
- **Floor4 / Sky Lounge** — jacuzzi, bar, DJ booth. Gold trim
  (`Color3.fromRGB(255, 200, 60)`).
- **Floor5 / Helipad Suite** — rooftop, parked cosmetic chopper,
  observation deck. Emerald trim (`Color3.fromRGB(80, 255, 140)`).
- **Floor6 / Sky Vault** — gold/marble vault, rotating brainrot statue.
  Gold/rainbow trim (`Color3.fromRGB(255, 215, 100)`).

The accent colors above match the `accentColor` field in `PlotConfig.TIERS`
and are also used for the upgrade-pad billboard text and toast styling.

## Runtime Behavior You Don't Need To Build

The PlotService takes care of the following automatically — DO NOT bake
these into the model:

- Hiding floors above the player's current tier (it transparency-pulls every
  BasePart in the floor and disables every Light + ProximityPrompt). The
  original transparency/CanCollide/Enabled values are cached as instance
  attributes the first time a floor is hidden, so you can build floors in
  the "fully visible" state.
- Adding/removing the place / collect / upgrade `ProximityPrompts` on the
  pad parts.
- Adding the floating billboard labels above each pad.

So just build the geometry + decor + named structural parts and the runtime
wires everything else up.

## Migration From The Old Flat Layout

Existing bases that have `PadGroup1..PadGroup10` directly under `BaseN`
(no `Floor1` wrapper) keep working as a Tier 1 base — `buildSlotMap` falls
back to a flat search when no `FloorN` containers exist. To enable
upgrades for those bases, wrap the existing pads in a `Floor1` model and
add `Floor2..Floor6` plus their upgrade pads.

## Optional: Single Template + Programmatic Cloning

If you'd rather build one tower and have the runtime clone it 6× into
`Workspace.Bases.Base1..Base6`, build the prefab as `ServerStorage.BaseTemplate`
and add a small `Bootstrap`-time cloner. This isn't shipped today — flag if
you want it implemented.
