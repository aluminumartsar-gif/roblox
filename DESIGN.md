# DESIGN.md — Steal a Cryptid

*Working title. Roblox. Designer/owner: user. Engineering: Claude.*

> Every number in this document is mirrored in
> `src/shared/Config.luau` (`ReplicatedStorage/Shared/Config`), which is the
> authority. If the two disagree, Config wins and this file is stale — fix it.

---

## 1. Pitch

Buy cryptid eggs. Incubate them in nests on your plot. Hatch them into cryptids
that print cash. Steal from everyone else.

A "steal-a-" style RNG game set in cozy-spooky night woods: campsites and cabins
in a ring around a central hub, lanterns, low fog, and a wild forest ring —
**The Wilds** — outside the plots.

The fantasy is amateur cryptozoology at 2am: your little camp, your nests
glowing in the dark, and the constant low-grade dread that someone is walking
onto your plot right now.

---

## 2. The three hooks

### Hook 1 — Patience odds

This is the core decision of the game and everything else serves it.

Each nest has a **Heat** meter that fills from 0 to 100 over 10 minutes. When
you hatch an egg, the weights of **Rare and above** are multiplied by

```
1 + 3 · (heat / 100)
```

…then all weights are renormalized. At heat 0 that multiplier is ×1; at heat
100 it is ×4. You can hatch at any moment via the prompt.

The tension: **an incubating egg can be stolen at any time, and the thief keeps
its heat.** A nest at 95 heat is the most valuable and most tempting object on
the map. Hatch now for worse odds, or wait five more minutes and risk losing it
entirely? That decision, repeated, is the game.

Luck (from rebirths, VIP, potions, codex pages) multiplies on top of the heat
bonus, so a max-heat egg on a high-luck account is genuinely spectacular — and
genuinely worth stealing.

### Hook 2 — Sightings

Every 6–10 minutes, a wild cryptid spawns somewhere in The Wilds and stays for
90 seconds. A server-wide banner and countdown announce it, so everyone knows.

- Spawn rarity: Rare 60% / Epic 30% / Legendary 9% / Mythic 1%, weighted rarer
  the more players are online.
- Near the sighting the world goes **VHS**: a ColorCorrection tint, a grain
  overlay, and a slight FOV wobble. You are looking at found footage.
- **Capture** is a 5-second contested hold. Taking damage interrupts you. So
  does another player starting their own hold.
- The winner does not get the cryptid handed to them. They have to **carry it
  home** like a stolen item — overhead, slowed, visible from across the map.
  Anyone can jump them on the way.

A sighting is a scheduled server-wide fight that everybody sees coming.

### Hook 3 — Codex *(Step 7)*

A camera tool photographs any cryptid on any plot — yours or someone else's —
into the **Cryptid Codex**: a grainy ViewportFrame "evidence" page.

Completing a rarity page grants a permanent luck bonus. The Codex **survives
rebirth**, so it is the one thing that always accumulates. It also gives a
non-violent reason to walk onto someone else's plot, which makes every visitor
ambiguous.

---

## 3. Economy

**Currency: Cash only.** Plus a Rebirth count. No secondary currency, ever —
the whole economy stays legible.

### Rarities

| Rarity    | Base odds (Forest egg) | Income/sec |
|-----------|-----------------------:|-----------:|
| Common    | 55%     | $1     |
| Uncommon  | 27%     | $4     |
| Rare      | 12%     | $15    |
| Epic      | 4.5%    | $60    |
| Legendary | 1.2%    | $250   |
| Mythic    | 0.25%   | $1,200 |
| Secret    | 0.05%   | $6,000 |

### Creatures (30)

Common through Legendary are **real folklore cryptids** (public domain).
Mythic and Secret are **originals**. No creepypasta, no artist-owned
characters, no trademarked names — ever.

- **Common (6):** Jackalope, Hodag, Drop Bear, Snallygaster, Gremlin,
  Wolpertinger
- **Uncommon (6):** Chupacabra, Fresno Nightcrawler, Loveland Frog, Goatman,
  Beast of Bray Road, Squonk
- **Rare (5):** Yeti, Ogopogo, Dover Demon, Flatwoods Monster, Jersey Devil
- **Epic (5):** Mothman, Bigfoot, Thunderbird, Bunyip, Mongolian Death Worm
- **Legendary (4):** Nessie, Kraken, Ningen, Mokele-Mbembe
- **Mythic (3), originals:** The Static, The Signal, The Hollow
- **Secret (1), original:** **[REDACTED]** — never renders clearly (noise/static
  material), unique sound, server-wide announcement on hatch

### Mutations *(later layer, data already in Config)*

Shiny ×1.5, Radioactive ×3, Spectral ×5 income. Off at launch; the profile
schema carries a Mutation field from day one so enabling it needs no migration.

### Eggs

Higher tiers shift the base odds toward rarer outcomes. Buying an egg places it
in an empty nest. **No empty nest = blocked with a message** (never a silent
failure, never a lost purchase).

| Egg       | Price   | Unlock      |
|-----------|--------:|-------------|
| Forest    | $100    | —           |
| Swamp     | $1K     | —           |
| Mountain  | $10K    | —           |
| Deep Sea  | $100K   | —           |
| Sky       | $1M     | Rebirth 1+  |
| Void      | $25M    | Rebirth 3+  |

Exact per-egg weight tables live in `Config.Eggs`.

---

## 4. The plot

Each player claims a plot on join and releases it on leave. Ten plots in a ring
around the hub.

- **6 nests** at start, **12 max** via upgrades (plus 4 from the +4 Nests pass).
- A nest holds **an egg OR a creature** — never both. This is what makes nest
  slots the real bottleneck: every creature you keep is an egg you can't cook.
- Creatures accrue cash into a per-creature vault. **Touch to collect.** The
  Auto Collect pass collects for you. Vault cap is upgradeable — an
  uncollected full vault is wasted income, which keeps players moving around
  and therefore stealable.
- The base has **walls and a door that opens only for the owner**.
- **Lock button:** 60-second lock, 5-minute cooldown. Extended Lock pass makes
  it 3 minutes.
- The owner gets **+15% walk speed on their own plot** — defender's advantage.

---

## 5. Stealing

On an **unlocked** plot, hold the prompt for **3 seconds** on an egg or a
creature.

**The owner gets:**
- an alarm
- a red outline on the item being taken
- the thief's name on screen

**The thief:**
- carries the item overhead, visible from a distance
- moves at **−25% speed**
- **cannot lock their own base while carrying**
- claims the item by touching their own plot's pad

**Losing it:**
- If the thief dies, or is hit by the owner's **Bat** (starter tool: knockback
  + 1s stun, 0.5s cooldown, no damage), the item **drops where they stand** and
  anyone can pick it up.
- An unclaimed item **returns home after 60 seconds**.

**Friction rules:**
- 30-second cooldown after a successful steal.
- The same item cannot be stolen twice within 2 minutes.
- New players get a **5-minute spawn lock**.

Stolen eggs keep their heat. That is the entire reason stealing matters.

---

## 6. Rebirth

- **Cost:** `$50,000 × 2.2^rebirths`
- **Requires:** owning at least one Rare-or-better creature
- **Resets:** cash, eggs, creatures, upgrades
- **Keeps:** codex, game passes, rebirth count, stats, purchase history
- **Each rebirth grants:** +25% income, +10% luck, a new nest glow color
- **Unlocks:** Sky egg at rebirth 1, Void egg at rebirth 3

---

## 7. Shops

- **Egg Shop** — a hub building. Browse eggs, see odds, buy.
- **Upgrade Shop** — nest slots, incubation speed, vault size, lock duration,
  walk speed. Level tables in `Config.Upgrades`.
- **Robux Shop** — UI panel for passes and products.

---

## 8. Monetization

Created in the Creator Dashboard by the owner; IDs pasted into
`Config.GamePasses` / `Config.DevProducts`. **Until then every Id is `0`, and
code must treat `0` as "not configured" and skip it gracefully.**

**Game Passes**

| Pass          | R$  | Effect                          |
|---------------|----:|---------------------------------|
| 2× Cash       | 399 | All income doubled              |
| +4 Nests      | 299 | Four extra nest slots           |
| Auto Collect  | 149 | Cash collects itself            |
| VIP           | 599 | Chat tag, +10% luck, gold nests |
| Extended Lock | 199 | 3-minute locks                  |

**Dev Products**

| Product        | R$  | Effect                          |
|----------------|----:|---------------------------------|
| Pocket Change  |  99 | $25,000                         |
| Stash          | 399 | $300,000                        |
| Hoard          | 999 | $5,000,000                      |
| Luck Potion    |  49 | +50% luck for 15 min            |
| Nest Warmer    |  29 | 2× heat rate for 10 min         |
| Max Heat       |  99 | One egg jumps to 100 heat       |
| Emergency Lock |  49 | +2 minutes on your current lock |
| 3-Egg Bundle   |  79 | Three Forest eggs               |

**`ProcessReceipt` must be idempotent.** Record the `PurchaseId` in the
player's profile *before* granting the reward, and return
`NotProcessedYet` on any failure so Roblox retries.

---

## 9. Data

Use **ProfileStore** (loleris) as a ModuleScript if it can be added. Otherwise a
minimal session-locked DataStore wrapper: `UpdateAsync`, retry with backoff,
autosave every 60s, save on leave, save in `BindToClose`.

The profile holds: cash, rebirths, nests (per slot: egg or creature + heat),
upgrades, codex, purchase history, stats.

---

## 10. Anti-exploit and performance

- All checks server-side. Clients send intent, never results.
- Income sanity caps — the server refuses any collect larger than what the
  player's owned creatures could plausibly have produced.
- Rate limits on every remote (`Config.Remotes[*].MaxPerMinute` plus a global
  backstop).
- `StreamingEnabled`, low-poly creatures, part budget per creature.
- `CollectionService` tags for nests, creatures, plots — never name lookups.

---

## 11. UI

Must work on a phone. Everything hold-to-interact is a ProximityPrompt.

- **HUD:** cash, rebirths, active buffs
- **Bottom bar:** Eggs, Upgrades, Rebirth, Codex, Robux
- **Plot panel:** Lock button + timer, nests used
- **Notification feed:** purchases, steals, hatches
- **Sighting banner:** with countdown

---

## 12. Atmosphere

Night. `ClockTime` just past midnight, low warm lanterns against cold blue
ambient, fog from 60 to 480 studs. The hub is lit and safe-feeling; The Wilds
are not. Near a sighting, the whole screen degrades to VHS.

The visual target is *cozy* first and *spooky* second — a campsite you'd want to
sit at, that happens to be surrounded by things with too many eyes.
