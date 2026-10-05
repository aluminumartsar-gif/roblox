# LAUNCH.md — getting Steal a Cryptid live

Everything here is something only the owner can do (Studio menus or the
Creator Dashboard). Text is ready to paste.

---

## 1. In Studio, once

1. **Grass blades:** Explorer → Workspace → Terrain → Properties → tick
   **Decoration**.
2. **Save:** File → Save to Roblox (keeps the terrain, the map preview and
   place settings).
3. **Quick phone check:** Test tab → Device → pick a phone (e.g. iPhone 14),
   Play, and open each screen (Store, Codex, Spin, Daily, Gifts, Upgrades,
   Rebirth, Settings). Everything should fit and be tappable.
4. **Two-player test:** Test tab → Clients and Servers → Players: 2 → Start.
   Try: steal an egg from the other player; bat a thief; let the Brood Mother
   (`game.ServerStorage.SAC_Debug:Invoke("hunt")` in the Server window) chase
   someone carrying an egg; race for a wild sighting
   (`SAC_Debug:Invoke("sighting")`).

## 2. Creator Dashboard → your experience

### Basic settings
- **Name:** Steal a Cryptid
- **Description** (paste):

  > Steal eggs. Hatch monsters. Don't get caught.
  >
  > Grab cryptid eggs off the belt, carry them back to your camp and guard
  > them until they hatch into creepy cryptids that earn you cash. Bigger eggs
  > take longer to hatch — and the whole time, anyone can sneak in and steal
  > them. So go steal theirs.
  >
  > 🥚 6 egg tiers, 30 cryptids from Jackalope to the Kraken — and things that
  > shouldn't exist
  > 🦇 Bat thieves out of your camp, lock your gate, or raid unlocked camps
  > 🌲 Wild cryptids appear in the woods — catch one and carry it home
  > 📷 Photograph every cryptid for your Codex for permanent luck
  > 👁️ When the fire gutters, the Brood Mother comes for anyone carrying an
  > egg. Stay in the light.
  >
  > Daily rewards, spin wheel, playtime gifts and offline earnings. Rebirth
  > for bigger eggs and more luck.

- **Genre:** Simulation (or Horror). **Max players / Server Size: 10**
  (= `Config.Plot.Count`; an 11th player would have no camp).
- **Maturity / content questionnaire:** the game has jumpscares, scary
  creatures and a hunting monster, no blood or gore. Answer the fear/horror
  questions honestly (expect a "Mild" or "Moderate" fear label).

### Icon and thumbnails
Take them in Studio with the game running (View → Screenshot, or the Studio
screenshot tool), at night with the lanterns lit:
- **Icon (512×512):** the Brood Mother's glowing eye looming over a single
  glowing egg, or a gaunt cryptid holding an egg — dark background, one bright
  focal point, big readable shapes.
- **Thumbnails (1920×1080):** (1) a thief running out of a camp with an egg
  overhead and the Brood Mother behind them; (2) the hub at night — belt,
  campfire, "STEAL A CRYPTID" arch; (3) a hatch reveal (Legendary rays);
  (4) a sighting with the VHS "REC" overlay.

### Monetization → Passes (create 5)
| Name          | Price | Description (paste) |
|---------------|------:|-------------|
| 2x Cash       | 399 | All cryptid income doubled, forever. |
| +4 Nests      | 299 | Four extra nests on top of your upgrades. |
| Auto Collect  | 149 | Your cryptids' cash collects itself. |
| VIP           | 599 | VIP chat tag, +10% luck and gold nests. |
| Extended Lock | 199 | Your camp lock lasts 3 minutes instead of 1. |

### Monetization → Developer Products (create 10)
| Name                | Price | Description (paste) |
|---------------------|------:|-------------|
| Pocket Change       |  99 | $25K cash. |
| Stash               | 399 | $300K cash. |
| Hoard               | 999 | $5M cash. |
| Luck Potion         |  49 | +50% luck for 15 minutes. |
| Hatch Boost         |  29 | Your eggs hatch 2x faster for 10 minutes. |
| Instant Hatch       |  99 | Hatch your best egg right now. |
| Emergency Lock      |  49 | Lock your camp for 2 minutes, right now. |
| 3-Egg Bundle        |  79 | Three Forest Eggs, straight into your nests. |
| 3 Extra Spins       |  49 | Three more spins of the wheel. |
| Double Offline Cash |  25 | Double the cash your cryptids earned while you were away. |

Then paste each **ID** into `src/shared/Config.luau`:
- passes → `Config.GamePasses.<Key>.Id` (DoubleCash, ExtraNests, AutoCollect,
  Vip, ExtendedLock)
- products → `Config.DevProducts.<Key>.Id` (CashSmall, CashMedium, CashLarge,
  LuckPotion, HatchBoost, InstantHatch, EmergencyLock, EggBundle, ExtraSpins,
  OfflineDouble)

(Or send the IDs to Claude and it will paste them and test each purchase in
Studio.) The boot log line `[SAC/Robux] Ready — N of 15 passes/products have
real ids` shows progress.

## 3. Publish
File → Publish to Roblox. Live servers save to `Config.Data.StoreScope`
("live1"), so launch starts from clean saves; your Studio testing stays in
its own scope.

## 4. After launch
- Watch the Developer Console (F9 in a live server) for `[SAC` warnings.
- Tune in `Config.luau` (no code changes needed): Brood Mother frequency and
  speed (`Config.Hunt`), hatch times and prices (`Config.Eggs`), belt odds
  (`Config.Belt.EggWeights`), rewards (`Config.Retention`), night brightness
  (`Config.Atmosphere`).
