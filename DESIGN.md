# DESIGN.md — Steal a Cryptid

*Roblox. Designer/owner: user. Engineering: Claude.*

> Every number in this document is mirrored in
> `src/shared/Config.luau` (`ReplicatedStorage/Shared/Config`), which is the
> authority. If the two disagree, Config wins and this file is stale — fix it.

---

## 1. Pitch

**Steal other people's eggs.** Grab cryptid eggs off the belt, carry them
home, and keep them safe until they hatch into cryptids that print cash —
while you sneak into other camps to take theirs. And at night, something in
the woods wants its eggs back.

A "steal-a-" style RNG game in dark night woods: palisade campsites in a ring
around a lantern-lit hub and its campfire, and a black forest — **The Wilds**
— all around. The cryptids are the scary part: gaunt, glowing-eyed folklore
monsters, not mascots.

---

## 2. The core loop: eggs

1. **Grab an egg off the belt.** A conveyor belt circles the hub campfire;
   a random egg climbs out of a burrow every 2 seconds. Tap Buy as it rides
   past — first come, first served. Rarer eggs are rarer on the belt.
2. **Carry it home.** It sits in your hand (you walk a little slower) and only
   becomes yours on your camp's **home pad**. Anyone can bat it out of your
   hand; a loose egg is anyone's for 30 seconds.
3. **Guard it until it hatches.** In a nest, an egg counts down its hatch time
   and **hatches by itself**. Better eggs take longer — and the whole time,
   anyone can walk in and steal it. A stolen egg keeps its progress.
4. **Hatch.** The server rolls a cryptid (fixed odds per egg, pushed rarer by
   luck), and a hatch reveal plays. Legendary and better are announced to
   the server.
5. **Earn.** Each cryptid fills its own vault with cash. Walk into it to
   collect. Hatched cryptids **can't be stolen** — they're your reward.
6. **Sell** cryptids you don't want (vault + 60 seconds of their income) to
   free the nest for a better egg.

### Eggs

| Egg      | Price | Hatch time | Unlock     | Belt chance | Common / Unc / Rare / Epic / Leg / Myth / Secret % |
|----------|------:|-----------:|------------|------------:|------|
| Forest   | $100  | 0:40 | —          | 50%  | 50 / 24.5 / 15.2 / 7.3 / 2.4 / 0.5 / 0.1 |
| Swamp    | $600  | 1:00 | —          | 26%  | 34.6 / 28.6 / 21.8 / 10.9 / 3.1 / 0.85 / 0.15 |
| Mountain | $4K   | 1:30 | —          | 14%  | 19.8 / 25.4 / 28.9 / 18.6 / 5.6 / 1.5 / 0.2 |
| Deep Sea | $30K  | 2:30 | —          | 6.5% | 8.5 / 17.6 / 31.6 / 27.9 / 11.6 / 2.5 / 0.3 |
| Sky      | $250K | 4:00 | Rebirth 1+ | 2.8% | 2.5 / 8.6 / 25.8 / 36.4 / 20.2 / 5.9 / 0.6 |
| Void     | $2.5M | 6:00 | Rebirth 3+ | 0.7% | 0 / 2 / 11.5 / 31.4 / 36.1 / 16.7 / 2.3 |

- **Luck** (rebirths +10% each, VIP +10%, Luck Potion +50%, each completed
  Codex page +5%; capped at +500%) multiplies the Rare-and-up weights.
- **Hatch Speed** (upgrade, up to 2x) and **Hatch Boost** (product, 2x for
  10 minutes) make eggs count down faster.
- **Big eggs advertise themselves.** A Sky or Void egg landing in a nest is
  announced to the whole server ("X has a VOID EGG hatching at their camp in
  6:00. Go get it!"). In the last 20% of any egg's countdown it glows red and
  throws a light pillar into the sky that the whole map can see.
- Eggs only count down while you're in the server.
- *Changed from heat (owner, Step 8):* the old design had a 0–100 "heat"
  meter that improved the odds the longer you waited. The owner cut it — the
  game is about stealing eggs, and the countdown makes the tension simpler:
  the closer an egg is to hatching, the juicier it is to steal.

### Rarities and income

| Rarity    | Income/sec |
|-----------|-----------:|
| Common    | $1     |
| Uncommon  | $4     |
| Rare      | $15    |
| Epic      | $60    |
| Legendary | $250   |
| Mythic    | $1,200 |
| Secret    | $6,000 |

Rebirths add +25% income each; the 2x Cash pass doubles it. Each cryptid's
vault holds the Vault Size upgrade's amount or 10 minutes of its own income,
whichever is bigger.

### Creatures (30)

Common through Legendary are **real folklore cryptids** (public domain).
Mythic and Secret are **originals**. No creepypasta, no artist-owned
characters, no trademarked names — ever. **They look scary**: generated
meshes in a dark, menacing folklore style (`Config.Art`, `docs/ART.md`).

- **Common (6):** Jackalope, Hodag, Drop Bear, Snallygaster, Gremlin,
  Wolpertinger
- **Uncommon (6):** Chupacabra, Fresno Nightcrawler, Loveland Frog, Goatman,
  Beast of Bray Road, Squonk
- **Rare (5):** Yeti, Ogopogo, Dover Demon, Flatwoods Monster, Jersey Devil
- **Epic (5):** Mothman, Bigfoot, Thunderbird, Bunyip, Mongolian Death Worm
- **Legendary (4):** Nessie, Kraken, Ningen, Mokele-Mbembe
- **Mythic (3), originals:** The Static, The Signal, The Hollow
- **Secret (1), original:** **[REDACTED]** — never renders clearly (a
  flickering ForceField silhouette), its name scrambles, server-wide
  announcement on hatch

### Mutations *(later layer, data already in Config)*

Shiny ×1.5, Radioactive ×3, Spectral ×5 income. Off at launch
(`Config.MutationsEnabled`); the profile carries a Mutation field already.

### The egg belt

- Every 2 seconds a random egg (`Config.Belt.EggWeights`) climbs out of a
  burrow, rides ~30 seconds round the campfire and sinks into a second
  burrow. An odds board beside the arch shows each egg's chance.
- Tap Buy while it rides past; you need empty hands and a free nest. Eggs
  above your rebirth level ride past marked "Rebirth N".
- Sky and Void eggs sparkle and announce themselves when they come out.
- Leaving with an egg in hand saves it for your next free nest (you paid).
- The HUD **Eggs** button fast-travels to the arch (not while carrying).

---

## 3. Stealing (eggs only)

On an **unlocked**, not-spawn-protected camp, hold **Steal** for 3 seconds on
an egg.

**The owner gets:** an alarm the moment the hold starts, the thief's name on
screen, and a red outline on their egg wherever it goes.

**The thief:** carries the egg overhead, visible from a distance, at −25%
speed; can't lock their own camp or fast-travel while carrying; claims it by
touching their own home pad (needs a free nest). The egg keeps its progress.

**Losing it:** a Bat hit or dying drops it where you stand — anyone can pick
it up (the owner picking it up sends it straight home). Unclaimed, it runs
home 60 seconds after the steal. The Brood Mother takes it back (below).

**Friction:** 20-second cooldown after a successful steal; the same egg can't
be stolen again for 2 minutes; spawn protection on every join (5 minutes the
first time, 2 after — stealing yourself ends it). The owner leaving forfeits
an egg that's out being carried (no rage-quitting to save it).

**Defending:** the **Lock** (60s, longer with the Lock Duration upgrade or the
Extended Lock pass; 5-minute cooldown from activation) makes the doorway a
wall only the owner can pass and puts anyone inside outside. Owners walk 15%
faster on their own camp. Everyone has a **Bat** (knockback + 1s stun, no
damage, 1.5s stun immunity after).

Dupe safety: the owner's slot stays (marked Away) until the claim, and the
claim moves it to the thief in one step, saving the owner first.

---

## 4. The scary twist: the Brood Mother

Every 7–10 minutes the campfire gutters, the lights dim, fog rolls in, and a
wail comes out of the woods. **The Brood Mother** — an original, towering,
gaunt thing with a cracked eggshell skull and one huge glowing eye, mother of
every egg in the woods — rises out of a nest of black branches in The Wilds.
She has come to take her eggs back.

- **She hunts whoever is carrying an egg** — a stolen one or a fresh one off
  the belt — anywhere within 260 studs. With no carrier near, she stalks
  anyone in the open within 90 studs.
- She glides through trees (she's a ghost) at 15 studs/s (17 while chasing a
  carrier). Players walk at 16+ and carry at 12–14, so a carrier caught in
  the open has to run for it — or hide.
- **Safe places:** inside any camp, and within the campfire's light at the
  hub. She will never cross into either.
- **Caught:** a jumpscare (her face fills your screen with a scream), a
  2.5-second stun and knockback, and she takes back what you carried: a
  stolen egg goes home to its owner, a belt egg or a captured cryptid is gone.
  She won't come for the same player again for 25 seconds.
- **Dread:** a banner and countdown ("Something stirs in the woods..." →
  "THE BROOD MOTHER IS HUNTING" / "SHE'S COMING FOR YOU"), a heartbeat that
  speeds up as she gets closer, red vignette and film grain, camera shake when
  she's near. She hunts for 70 seconds, then sinks back into the ground.
- Hunts and sightings never overlap.

The point: carrying an egg is always a risk, and at night it's a terror —
which is exactly when thieves are out.

---

## 5. Sightings — wild cryptids

- **When:** the first one 2 minutes after the first player loads into a
  fresh server, then 6–10 minutes after the previous one ended. One at a
  time, never during a Hunt, none while the server is empty.
- **Odds:** Rare 60 / Epic 30 / Legendary 9 / Mythic 1. For every player
  beyond the first (up to 20), 3% of the Rare weight moves into Epic and up:
  a full server rolls about Rare 26 / Epic 56 / Legendary 17 / Mythic 2.
- **Where:** a random open spot in The Wilds found by raycasts. A tall light
  pillar in the rarity colour marks it, the banner gives a rough direction
  ("north-east Wilds, behind Alex's camp"), and a floating marker shows the
  distance.
- **Capturing:** hold Capture for 5 seconds. Starting a hold breaks anyone
  else's (they're told who); a Bat bonk or losing health breaks yours. You
  need a free nest and empty hands.
- **Carrying it home:** overhead, slowed, outlined through walls with its own
  light pillar — everyone sees you, including the Brood Mother. Knocked
  loose, anyone with a free nest can grab it for 30 seconds before it
  escapes. Leaving the game loses it. On your pad it goes into a free nest.
- **VHS:** within 120 studs the screen goes found-footage — tint, scanlines,
  grain, a "REC" timecode and a slight FOV wobble.

---

## 6. The Codex

- **Field Camera:** every player gets one each spawn, next to the Bat. It
  shows a camcorder viewfinder and names the cryptid you're aiming at. Click
  or tap to photograph: any cryptid in any nest, a wild sighting, or one
  someone is carrying — within 60 studs, clear view, one photo every 2
  seconds. On a phone the cryptid nearest the middle of the screen counts.
- Hatching or bringing home a cryptid logs it automatically.
- **New entry:** a "NEW CODEX ENTRY" polaroid (after any hatch reveal).
  **Page complete** (every cryptid of one rarity): "+5% luck forever",
  announced to the server. 7 pages = up to +35% luck, kept through rebirth.
- **Codex screen** (HUD Codex button, "!" when something new was logged): a
  card per cryptid as an evidence photo, or a black silhouette with "???";
  the Secret is always glitched. Filters per rarity with progress, search by
  name, and a one-line field note per cryptid (`Config.Codex.Blurbs`).
- It gives a non-violent reason to walk into someone else's camp — which
  makes every visitor ambiguous.

---

## 7. Rebirth

- **Cost:** `$75,000 × 2.2^rebirths`. **Requires** a Rare-or-better cryptid
  at home. Refused while you're carrying a stolen egg or one of yours is out.
- **Resets:** cash (you restart with **$1,500**), nests, upgrades.
- **Keeps:** Codex, game passes, rebirth count, stats, purchase history,
  active potions.
- **Each rebirth:** +25% income, +10% luck, a new nest glow colour.
  Sky eggs unlock at rebirth 1, Void at 3.

---

## 8. Shops and upgrades

- **Egg belt** — round the hub campfire (above).
- **Upgrades cabin** — in the hub. Level tables in `Config.Upgrades`:

| Upgrade       | Levels (value @ cost) |
|---------------|------|
| Nest Slots    | 6, 7 @ $1K, 8 @ $6K, 9 @ $30K, 10 @ $150K, 11 @ $750K, 12 @ $4M |
| Hatch Speed   | 1x, 1.2x @ $200, 1.4x @ $3K, 1.6x @ $20K, 1.8x @ $120K, 2x @ $750K |
| Vault Size    | $25K, $75K @ $2.5K, $250K @ $15K, $1M @ $100K, $5M @ $600K, $25M @ $4M |
| Lock Duration | 60s, 75s @ $1.5K, 90s @ $10K, 110s @ $60K, 135s @ $400K |
| Walk Speed    | 16, 18 @ $500, 20 @ $5K, 22 @ $40K, 24 @ $300K |

- **Robux Store** — HUD Store button.

---

## 9. Monetization

Created in the Creator Dashboard by the owner; IDs pasted into
`Config.GamePasses` / `Config.DevProducts`. Until then every Id is `0`: the
item shows SOON and the server refuses it.

**Game Passes**

| Pass          | R$  | Effect                          |
|---------------|----:|---------------------------------|
| 2× Cash       | 399 | All income doubled              |
| +4 Nests      | 299 | Four extra nest slots           |
| Auto Collect  | 149 | Cash collects itself            |
| VIP           | 599 | Chat tag, +10% luck, gold nests |
| Extended Lock | 199 | 3-minute locks                  |

**Dev Products**

| Product             | R$  | Effect                                        |
|---------------------|----:|-----------------------------------------------|
| Pocket Change       |  99 | $25,000                                       |
| Stash               | 399 | $300,000                                      |
| Hoard               | 999 | $5,000,000                                    |
| Luck Potion         |  49 | +50% luck for 15 min                          |
| Hatch Boost         |  29 | Eggs hatch 2x faster for 10 min               |
| Instant Hatch       |  99 | Your best egg hatches right now (saved if none) |
| Emergency Lock      |  49 | Lock your camp for 2 min now (or +2 min)      |
| 3-Egg Bundle        |  79 | Three Forest eggs (saved if nests are full)   |
| 3 Extra Spins       | ~49 | Spin Wheel spins (sold on the wheel screen)   |
| Double Offline Cash | ~25 | Doubles waiting offline cash (offline popup)  |

`ProcessReceipt` is idempotent: the PurchaseId is recorded with the grant in
one synchronous step and saved before `PurchaseGranted`; retries re-save
only. Potions stack by extending their time.

### Retention (Step 7.5)

All decided on the server (`RetentionService`, `Config.Retention`).
**Rewards** are lists of items: cash that scales with you (the bigger of a
fixed amount and N minutes of your creature income, capped), eggs (into a free
nest, else saved), Luck Potion / Hatch Boost time, and Instant Hatch.

- **Daily Rewards** (HUD Daily, bottom right; pops up once on joining when
  claimable): one claim per UTC day, streak resets if you miss a day, 7-day
  cycle with a big day 7.
- **Spin Wheel** (HUD Spin): one free spin every 4 hours (a new player has one
  ready), extra spins from the product. Six prizes; the server rolls and pays,
  the wheel animates to the prize.
- **Playtime Gifts** (HUD Gifts: countdown, "Claim!"): unlock at 2, 5, 10,
  15, 25, 40 and 60 minutes into a visit.
- **Offline Earnings:** away 5+ minutes → 25% of your creature income for the
  time away (up to 8 hours), saved the moment you join; CLAIM or CLAIM 2x.

---

## 10. The world

- **Generated by code** (`Modules/MapBuilder` from `Config.Map`/`Config.Plot`),
  rebuilt every boot: Terrain grass and dirt paths, rolling hills in The
  Wilds, ten log-palisade campsites (walls above jump height, a gate with the
  camp name, twig nests, a tent, campfire, lanterns, a glowing HOME PAD and a
  red lock button), a stone-edged hub with the belt round the campfire, the
  Upgrades cabin, a totem, leaderboards and a "STEAL A CRYPTID" arch, and a
  dense forest of pines, boulders, fallen logs and glowing mushrooms.
- **Art:** generated meshes (`Config.Art`, built into templates by
  `ArtService` at boot; part-built fallbacks if a mesh is missing).
- **Night:** just past midnight, cold blue moonlight against warm lanterns and
  firelight, fog hiding the edge of the world. **Every player carries a small
  lantern glow** — you can see around you, and you can see other players'
  lights moving through the dark.
- **Leaderboards** in the hub: total cash earned, rebirths, steals (global,
  OrderedDataStores, refreshed every minute).

---

## 11. Feel

- **Sound:** eerie low music, crickets and owls under a breathing, creaking
  dread bed; a campfire crackle at the hub; stings for every hatch rarity;
  alarms, bonks, coins, the Brood Mother's wail, heartbeat and scream
  (`Config.Sounds`; licensed Roblox / APM / Pro Sound Effects audio).
- **Hatch reveal:** the cryptid spinning in rarity-coloured light rays, a
  RARITY stamp, its income and the egg it came from; Legendary+ adds shake
  and confetti; Secret gets static and a scrambling name.
- **Cash:** floating "+$X" at the cryptid and a bounce on the HUD cash.
- **Nest labels:** small and stud-sized (they shrink with distance); eggs
  show a countdown bar, cryptids their name, rarity colour and income (and
  your vault on your own). Cryptids breathe and look around; eggs about to
  hatch wobble; Legendary+ have a faint aura.
- **First-join tutorial:** welcome → grab an egg → carry it home → guard it
  until it hatches → collect → tips (including the Brood Mother). Veterans
  never see it.

---

## 12. UI

Must work on a phone. Everything hold-to-interact is a ProximityPrompt. The
look comes from the owner's purchased STUD UI kit; our code fills its
screens (the kit's own shop scripts are not used).

- **HUD:** cash and rebirth bonus (bottom left, "+" opens the Store); side
  buttons Store, Codex, Gifts, Spin, Rebirth ("!" when ready), Invite,
  Settings; Daily (bottom right); **Base** and **Eggs** fast travel at the top
  (8s cooldown, not while carrying or stunned); quick-buys for the Luck
  Potion and 3-Egg Bundle; buff timers above the cash.
- **Screens:** Store, Rebirth (+ confirm), Upgrades, Settings (sounds and
  music), Codex, Daily Rewards, Spin Wheel, Playtime Gifts, Offline popup.
  One open at a time; shop screens close when you walk away.
- **Plot panel:** one row, top left — protection timer, nests used, Lock.
- **Banners:** sightings and the Hunt, top centre; toasts slide in below them.

---

## 13. Data and anti-exploit

- One session-locked profile per player (`Modules/SessionStore`), autosave
  every 60s, save on leave and shutdown. A profile that can't load safely
  kicks rather than playing on a blank one. Schema v2 (migration from v1
  converts heat to hatch progress).
- Live servers save to `Config.Data.StoreScope`; **Studio play tests save to
  `StudioStoreScope`**, so testing never touches real players.
- All checks server-side; clients send intent only. Rate limits on every
  remote. Prompts re-check owner, distance and hold time on the server.
- `StreamingEnabled`; CollectionService tags, never name lookups.
