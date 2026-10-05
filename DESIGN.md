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
you hatch an egg, each rarity's weight is multiplied by

```
1 + (M − 1) · (heat / 100)
```

…where **M** is that rarity's full-heat multiplier, then all weights are
renormalized. Rarer outcomes climb faster:

| Rarity     | M at full heat |
|------------|---------------:|
| Common     | ×1 (no boost)  |
| Uncommon   | ×1 (no boost)  |
| Rare       | ×2             |
| Epic       | ×3             |
| Legendary  | ×4             |
| Mythic     | ×5             |
| Secret     | ×6             |

*(Changed at Step 1 from a flat ×4 on everything Rare+. The flat version
barely moved high-tier eggs: on a Void egg, max heat changed Legendary odds
×1.03. Scaling by rarity keeps heat meaningful at every tier.)*

Measured effect on Legendary-or-better odds, heat 0 → 100:

| Egg      | Heat 0 | Heat 100 | Gain  |
|----------|-------:|---------:|------:|
| Forest   | 1.50%  | 5.05%    | ×3.36 |
| Swamp    | 2.00%  | 6.10%    | ×3.05 |
| Mountain | 4.00%  | 10.24%   | ×2.56 |
| Deep Sea | 9.00%  | 18.40%   | ×2.04 |
| Sky      | 19.0%  | 31.2%    | ×1.64 |
| Void     | 46.0%  | 59.1%    | ×1.29 |

You can hatch at any moment via the prompt.

The tension: **an incubating egg can be stolen at any time, and the thief keeps
its heat.** A nest at 95 heat is the most valuable and most tempting object on
the map. Hatch now for worse odds, or wait five more minutes and risk losing it
entirely? That decision, repeated, is the game.

Luck (from rebirths, VIP, potions, codex pages) multiplies on top of the heat
bonus for every boosted rarity (Rare and up), so a max-heat egg on a high-luck
account is genuinely spectacular — and genuinely worth stealing.

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

#### As built (Step 7)

- **When:** the first one 2 minutes after the first player loads into a
  fresh server, then 6–10 minutes after the previous one ended (caught or
  escaped). One at a time, and none while the server is empty (if everyone
  leaves, a live one escapes).
- **Odds:** Rare 60 / Epic 30 / Legendary 9 / Mythic 1. For every player
  beyond the first (up to 20), 3% of the Rare weight moves into Epic and up
  (in proportion): a full server rolls about Rare 26 / Epic 56 /
  Legendary 17 / Mythic 2. `SAC_Debug
  sightings` prints the odds right now.
- **Where:** a random open spot in The Wilds — on walkable ground, not too
  steep, not inside a tree or rock — found by raycasts, so it keeps working
  when the map art changes. A tall light pillar in the rarity colour marks
  it across the map, the banner gives a rough direction ("north-east Wilds,
  behind Alex's camp"), and a floating marker with the distance points the
  way.
- **Capturing:** hold Capture for 5 seconds. Starting a hold breaks anyone
  else's (they're told who), and getting bonked by a Bat or losing health
  breaks yours. You need a free nest and empty hands to start.
- **Carrying it home:** over your head, slowed like a thief, outlined
  through walls with its own light pillar — everyone sees you. No timer
  while you hold it. Knocked loose, anyone with a free nest can grab it for
  30 seconds before it escapes for good; leaving the game loses it (it's
  dropped for the others to grab, or escapes). On your pad it goes into a free nest (full nests: you're told to
  make room). You can't lock your camp or fast-travel while carrying it.
- **VHS:** within 120 studs the screen tints, loses colour, gains
  scanlines, grain, a "REC" timecode and a slight FOV wobble, strongest
  within 40 studs; it fades away when you leave or the sighting ends.

### Hook 3 — Codex *(Step 7)*

A camera tool photographs any cryptid on any plot — yours or someone else's —
into the **Cryptid Codex**: a grainy ViewportFrame "evidence" page.

Completing a rarity page grants a permanent luck bonus. The Codex **survives
rebirth**, so it is the one thing that always accumulates. It also gives a
non-violent reason to walk onto someone else's plot, which makes every visitor
ambiguous.

#### As built (Step 7)

- **Field Camera:** every player gets one each spawn, next to the Bat.
  Holding it shows a camcorder viewfinder (corner brackets, blinking REC,
  a battery that recharges between shots, the night clock) and names the
  cryptid you're aiming at, outlined in its rarity colour, with "NEW! Not
  in your Codex yet" when it would be a new entry. Click (PC) or tap
  (phone) to take a photo: white flash and shutter sound every time.
- **What counts:** any cryptid in any nest (yours or anyone's), a wild
  sighting, or one someone is carrying. Within 60 studs, with a clear view
  (walls block; people, glass and see-through things don't), one photo
  every 2 seconds. On a phone you don't need to be exact: the cryptid
  nearest the middle of the screen counts.
- **Logged automatically, too:** anything you hatch, and anything you
  bring home (stolen or captured). Already-known cryptids are skipped
  silently.
- **New entry:** a "NEW CODEX ENTRY" polaroid drops onto the screen.
  **Page complete** (every cryptid of one rarity): a gold banner,
  "+5% luck forever", announced to the whole server and saved at once.
  7 pages = up to +35% luck, kept through rebirth.
- **Codex screen** (HUD Index button, red "!" when something new was
  logged): a card per cryptid as an old evidence photo, or a black
  silhouette with "???" until you log it. The Secret's photo is always
  glitched and redacted. Filter buttons per rarity show progress
  ("Rare 3/5"); the header shows pages complete and the luck they give;
  search by name. Tap a card for its file: rarity, income, a one-line
  field note (Config.Codex.Blurbs), and whether you've photographed it.

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

Higher tiers shift the base odds toward rarer outcomes. Eggs come off the
**egg belt** (below); which egg comes out is random, so the higher tiers really
are rare. **No empty nest = blocked with a message** (never a silent failure,
never a lost purchase).

| Egg       | Price   | Unlock      | Belt chance |
|-----------|--------:|-------------|------------:|
| Forest    | $100    | —           | 50%         |
| Swamp     | $1K     | —           | 26%         |
| Mountain  | $10K    | —           | 14%         |
| Deep Sea  | $100K   | —           | 6.5%        |
| Sky       | $1M     | Rebirth 1+  | 2.8%        |
| Void      | $25M    | Rebirth 3+  | 0.7%        |

Exact per-egg weight tables live in `Config.Eggs`; belt chances in
`Config.Belt.EggWeights`.

### The egg belt (Step 6.6, owner request — replaced the Egg Shop)

A circular conveyor belt round the hub campfire. Every 2 seconds a random egg
climbs out of a glowing burrow, rides about 30 seconds round the ring, and
sinks into a second burrow at the end. An arch over the gap between the
burrows is the way in to the campfire; an odds board beside it shows each
egg's chance.

- **First come, first served.** Tap the egg's Buy prompt (E / tap) while it
  rides past. The first player to finish gets it; it leaves the belt.
- **Carry it home.** The egg goes in your left hand (you walk a little
  slower). It only becomes yours when you step on your camp's pad — then it
  goes in a free nest.
- **Knock it loose.** Anyone who bats you knocks the egg out of your hand.
  It lands on the ground and **anyone** can grab it (including you) for 30
  seconds; after that it's gone. You paid, so you lose the cash.
- One egg in your hands at a time; you need a free nest to buy or grab one.
- Eggs above your rebirth level still ride past, showing "Rebirth N"
  instead of a price, and can't be bought.
- Sky and Void eggs sparkle and announce themselves to the server.
- Leaving the game with an egg in hand saves it for your next free nest
  (you paid for it). Fast travel is off while carrying.
- HUD **Eggs** button fast-travels to the arch.

### How the egg loop works

1. **Buy** off the egg belt and carry it home (above).
2. **Heat** builds while it sits (0→100% over 10 min; faster with the
   Incubation Speed upgrade or a Nest Warmer). Everyone can see an egg's heat
   on its label — a hot egg advertises itself to thieves.
3. **Hatch** with the egg's prompt (owner only). The roll happens on the
   server using the egg's current heat and your luck. The creature appears
   in the same nest. Legendary and better are announced to the whole server.
4. **Earn.** Each creature fills its own vault with cash. Walk into it to
   collect. A full vault stops filling.

Heat and income only tick while you're in the server (eggs keep the heat
they had when you left). Since Step 7.5 a quarter of your creature income
for the time away is paid as **offline cash** when you come back — see
"Retention (as built)" in §8.

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
- The base has **walls (too high to jump) and one doorway** facing the hub.
- **The doorway is open by default** — that's how thieves get in.
- **Lock** (button on a stump inside the door, or the Lock button on the HUD
  panel): for 60 seconds the doorway becomes a barrier that **only the owner
  can pass**, and anyone already inside is put outside the door. 5-minute
  cooldown, counted from when you lock. Extended Lock pass makes it 3
  minutes. The LockDuration upgrade lengthens it.
- The server enforces the lock by position, not by the door part, so a
  hacked client that removes the barrier still gets ejected.
- You spawn and respawn **inside your own camp**.
- The owner gets **+15% walk speed on their own plot** — defender's advantage.

Layout (each plot is 80×80 studs, door facing the hub): claim pad and lock
button just inside the door, spawn point behind them, 12 nests in a 3×4
grid (only as many glow as you have nest slots), a tent and a small fire in
the back corners. A floating sign shows "<Name>'s Camp".

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

### As built (Step 4)

- **Who can steal what:** anyone but the owner, from a plot that's not
  locked and not spawn-protected, an item that isn't still guarded from a
  recent steal, while not already carrying something and not on cooldown,
  with a free nest at home to bring it to.
- **The owner is warned the moment the hold starts** — banner, alarm sound,
  red outline on the item — so a fast owner can stop a steal before it
  completes (walk up and Bat the thief).
- **The owner keeps the cash** a creature had already earned; the thief
  takes the cryptid, not the wallet.
- **While carried** the item is outlined red for its owner, through walls.
- **Spawn protection** on every join: 5 minutes the first time, 2 after.
  Starting a steal yourself ends it.
- **Any player's Bat** knocks a stolen item loose (the brief's "anyone can
  jump them on the way"). Being bonked stuns for 1s, then 1.5s of immunity
  so two players can't stun-lock someone.
- **Leaving:** a thief who leaves loses the item back to its owner; an owner
  who leaves while their item is out forfeits it — leaving can't be used to
  save an item.

---

## 6. Rebirth

- **Cost:** `$50,000 × 2.2^rebirths`
- **Requires:** owning at least one Rare-or-better creature
- **Resets:** cash, eggs, creatures, upgrades
- **Keeps:** codex, game passes, rebirth count, stats, purchase history
- **Each rebirth grants:** +25% income, +10% luck, a new nest glow color
- **Unlocks:** Sky egg at rebirth 1, Void egg at rebirth 3

As built (Step 5): the REBIRTH button on the plot panel opens a screen
showing the cost, whether you have a Rare+ at home, and exactly what you
lose / keep / gain. Rebirth is refused while you're carrying a stolen item
or while one of your own is out being stolen. The whole server is told
when someone rebirths.

---

## 7. Shops

- **Egg belt** — round the hub campfire (see Eggs). Replaced the Egg Shop
  building in Step 6.6.
- **Upgrade Shop** — the Upgrades cabin in the hub: nest slots, incubation
  speed, vault size, lock duration, walk speed. Level tables in
  `Config.Upgrades`. Bought at the counter; effects apply instantly.

**Vault cap:** each creature holds the Vault Size upgrade's amount, or 10
minutes of its own income if that's more — so a Mythic ($1.2K/s) holds
$720K and doesn't stop earning seconds after you collect.
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

### As built (Step 6)

- **Robux Shop:** the Store button on the HUD (kit Store screen since Step
  6.5): boosts, the egg bundle, Emergency Lock, passes, then cash packs.
  Prices come from Roblox once the real IDs are set; until then items show SOON and can't be bought.
- **Max Heat** goes to your most valuable egg that isn't already maxed.
  With no such egg, it's saved and hits your next egg automatically.
- **Emergency Lock** locks your camp immediately — even during the normal
  cooldown — for 2 minutes, or adds 2 minutes to a running lock.
- **3-Egg Bundle** fills free nests; any eggs that don't fit are saved and
  placed the moment a nest frees up. (The shop asks for at least one free
  nest before opening the purchase.)
- **Potions** stack: buying another while one is running adds its time.
  Active potions show on the HUD with a countdown.
- **VIP:** gold [VIP] chat tag, +10% luck, gold nest glow.

### Retention (as built, Step 7.5)

Four reasons to come back, all decided on the server (`RetentionService`)
and tuned in `Config.Retention`. The screens are the kit's DailyRewards,
SpinWheel, Rewards and OfflineRewardsPopup.

**Rewards** are lists of items, shared by all four features:
- **Cash** scales with you: the bigger of a fixed amount and N minutes of
  your current creature income (creatures at home), capped at $200M. So
  day-1 cash is worth having at $50/s and at $50K/s.
- **Eggs** go in a free nest, or are saved and placed when one frees up.
  An egg above your rebirth level becomes the best egg you *have* unlocked.
- **Luck Potion / Nest Warmer time** — adds to a running potion, exactly
  like buying one.
- **Max Heat** — your best egg, or saved for your next egg (as the product).

**Daily Rewards** (HUD Daily button, bottom right; pops up once on joining
when there's one to claim, after the offline popup)
- One claim per UTC day. Claim the next day to keep the streak; miss a day
  and you're back to day 1. After day 7 it starts again.
- Day 1 $500 / 3 min · Day 2 Swamp Egg · Day 3 $2K / 8 min · Day 4 Luck
  Potion 15m · Day 5 $5K / 15 min · Day 6 Mountain Egg + Nest Warmer 15m ·
  **Day 7** $25K / 45 min + Deep Sea Egg + Luck Potion 30m.
- 7 cards: ticked when claimed, "TODAY" (pulsing) when claimable — tap it.

**Spin Wheel** (HUD Spin button)
- One free spin every 4 hours of real time; a new player has one ready.
  More from the **3 Extra Spins** product (sold on the wheel screen).
- 6 prizes (the kit wheel has 6 slots), clockwise from the top: small cash
  30%, Mountain Egg 16%, medium cash 24%, Boost Pack (Luck + Warmer 10m)
  16%, Max Heat 8%, jackpot cash 6% (announced to the server).
- The server rolls and pays at once; the wheel then spins to land on the
  prize. The win message arrives when the wheel stops.

**Playtime Gifts** (HUD Gift button: countdown, "Claim!" when ready)
- Unlock at 2, 5, 10, 15, 25, 40 and 60 minutes into a visit; each opens
  once per visit and the clock restarts on every join.
- Small cash, a Swamp Egg, a Nest Warmer, and at 60 minutes a Mountain Egg
  + Luck Potion.

**Offline Earnings**
- Away 5 minutes or more: 25% of your creature income for the time away,
  up to 8 hours. Saved the moment you join (a crash can't lose it), and
  stacks if you leave without claiming.
- Popup: "your cryptids earned $X" → **CLAIM!** or **CLAIM 2x** (the
  **Double Offline Cash** product). Bought after claiming, Double pays the
  same amount again; with nothing to double the shop refuses, and a
  receipt that still arrives pays a small cash gift instead.

**New dev products** (both `Id = 0` until created): 3 Extra Spins (~R$49),
Double Offline Cash (~R$25). They're sold only on their own screens, not in
the Store — Double only makes sense with offline cash waiting.

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

The look comes from the owner's purchased STUD UI kit (Step 6.5). Our code
fills the kit's screens; the kit's own shop scripts are not used.

- **HUD:** cash and rebirth bonus (bottom left, "+" opens the Store); side
  buttons Store, Index (Codex, Step 7), Rebirth (red "!" when ready),
  Invite, Settings; top buttons **Base** and **Eggs** fast-travel you home or
  to the egg belt (8s cooldown, not while carrying or stunned); right-side
  quick-buys for the Luck Potion and 3-Egg Bundle; buff timers above the cash
- **Screens:** Store, Rebirth (+ confirm), Upgrades, Settings
  (sounds on/off). One open at a time; shop screens close when you walk away
- **Plot panel:** one row, top left — protection timer, nests used, Lock
  button. Our own UI scales with screen height so it fits phones
- **Kit screens waiting for later steps:** Index (Codex, Step 7), Daily
  Rewards, Spin Wheel, Playtime Gifts, Offline Earnings (Step 7.5)
- **Notification feed:** purchases, steals, hatches
- **Sighting banner:** with countdown

---

## 12. Atmosphere

Night. `ClockTime` just past midnight, low warm lanterns against cold blue
ambient, fog from 60 to 480 studs. The hub is lit and safe-feeling; The Wilds
are not. Near a sighting, the whole screen degrades to VHS.

The visual target is *cozy* first and *spooky* second — a campsite you'd want to
sit at, that happens to be surrounded by things with too many eyes.
