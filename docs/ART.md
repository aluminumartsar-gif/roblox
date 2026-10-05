# Art — generated meshes

Every creature, egg and world prop in the game is an AI-generated textured mesh
made with the Roblox Studio MCP tool `generate_mesh`. This file records the
exact prompt, settings and result for each one so any asset can be
regenerated later.

## How the art is wired in

- The ids live in `Config.Art` (`src/shared/Config.luau`):
  `Creatures[creatureId]`, `Eggs[eggId]`, `Props[propId]`. Each entry is
  `{ Mesh = "rbxassetid://…", Texture = "rbxassetid://…", Height = studs, Yaw = degrees }`.
- `ArtService` (server, runs first at boot) loads each mesh with
  `AssetService:CreateMeshPartAsync`, sets the texture, scales it so its
  standing height equals `Height`, turns it by `Yaw` around the vertical axis,
  pivots it at the bottom centre and stores it under
  `ReplicatedStorage.ArtTemplates`. Anything missing or failing to load falls
  back to the block placeholder, so a bad asset can never break the game.
  (`Config.Art.CreatureScale` then draws every creature a bit bigger than its
  `Height`.)
- Every creature (and the Brood Mother) must **face -Z**. Every mesh made so
  far came out of the generator already facing -Z, so every `Yaw` is 0. If a
  future mesh faces +Z use `Yaw = 180`; facing +X use `90`; facing -X use `-90`.
- Nothing generated needs to stay in Studio: the ids are permanent asset ids
  and ArtService rebuilds the models every boot.

## Regenerating an asset

Call `generate_mesh` (Edit mode, **not during a play test**) with:

| setting | value |
|---|---|
| `textPrompt` | the prompt from the tables below |
| `size` | the size from the tables below. The generator picks the proportions itself and scales the result to fit inside this box, so the box mostly sets the overall scale. To change proportions, say it in the prompt ("about four times taller than it is wide", "much wider than tall"). `Height` in Config does the final in-game scaling. |
| `segmentation` | `"none"` (one MeshPart) |
| `maxTriangles` | `3500` |
| `async` | `true`, then poll `wait_job_finished` (a job takes ~3–6 minutes) |

The finished Model appears in Workspace, named after the prompt, with one
MeshPart whose `MeshId` / `TextureID` go into Config.

**Creature style suffix** — appended to every creature prompt (the tables
write `+STYLE` where it applies):

> dark folklore cryptid, eerie and menacing, gaunt unsettling proportions, glowing eyes, mottled dark textures, stylized low-poly game creature, full body, facing forward

**Prop suffix**: `stylized low-poly game asset, spooky night campsite`.
**Egg suffix**: `ominous cryptid egg, <biome>, stylized low-poly game item`.

The first pass used a cute style ("cute stylized low-poly cartoon game style,
chunky proportions, big friendly eyes, full body, facing forward"); the owner
switched the direction to scary ("cryptids are scary creatures"), so every
creature was regenerated. The cute ids are listed at the bottom as fallbacks.

### Lessons learned

- **Run at most 2 jobs at once.** Six at once → most failed.
- **Never generate during a play test.** A job started or finishing while
  Studio is in Play mode fails ("Model generation should only be called from
  the server" or "Failed to publish assets … PreviewAssets not found"). Retry
  once Studio is back in Edit.
- **Moderation**: avoid gore/violence words (blood, gore, kill, demon, devil,
  death, monster, fangs, teeth). Fine in practice: eerie, menacing, gaunt,
  emaciated, hunched, towering, shadowy, ragged, feral, sharp spines/quills,
  long (hooked) claws, hollow glowing eyes, tattered wings, sinister. Describe
  the look rather than naming risky creatures (no "Jersey Devil", "Dover
  Demon", "Death Worm" in prompts). The only moderation rejection this pass
  was a Nessie prompt that said "Loch Ness plesiosaur … marine reptile …
  eerie and menacing".
- **Upright creatures**: "goat person standing upright" produced a four-legged
  goat twice. What works: "bipedal …-man standing tall and upright like a
  person, (gaunt) human-like torso with two (long thin) arms at its sides".
- **Odd body plans** need it spelled out: the Fresno Nightcrawler only came
  out right with "made of only two parts: a big round head, and two long stilt
  legs attached directly to the bottom of the head, absolutely no arms, no
  neck and no body".
- Naming the creature can hurt: "Jackalope: …" produced a deer.
- "no flames" still produced a campfire with a flame mesh; "cold extinguished
  fire pit … cold and dark" worked.
- Always QA: a "wide nest" prompt once came back as a single egg.

### How QA was done

Studio's viewport stopped rendering screenshots early in the session, so each
mesh was checked with a small software renderer instead: Luau in the Edit
datamodel loads the mesh and texture with `AssetService:CreateEditableMeshAsync`
/ `CreateEditableImageAsync`, rasterises a textured front view (camera on the
-Z side, `Yaw` applied) and a 3/4 view, and the image was decoded and
inspected. The front view confirms the face points at -Z.

## Creatures (Config.Art.Creatures)

| id | rarity | final prompt | size | Mesh | Texture | Height | Yaw | notes |
|---|---|---|---|---|---|---|---|---|
| jackalope | Common | gaunt feral hare with long sharp branching antlers, long rabbit ears, hollow glowing yellow eyes, ragged grey-brown fur, crouching on its hind legs, +STYLE | 2 x 3 x 2.6 | rbxassetid://131681255958586 | rbxassetid://79054338605187 | 3 | 0 | Excellent: dark feral hare, long antlers, glowing eyes. |
| hodag | Common | hulking dark grey-green lizard-ox creature standing on four thick legs, heavy curved ox horns, a row of sharp white spines along its back and thick tail, broad fierce face, +STYLE | 2.8 x 3 x 4.4 | rbxassetid://112139235538943 | rbxassetid://111351156320288 | 3 | 0 | Good: horned green lizard-beast with back spines (more gaunt than hulking). |
| drop_bear | Common | hunched ragged dark grey koala-like predator crouching low, unmistakable koala face with huge round fluffy tufted ears and a big black leathery nose, matted patchy fur, long thin arms with long hooked claws, pale glowing white eyes, +STYLE | 2.6 x 3 x 2.6 | rbxassetid://103810274470439 | rbxassetid://107743726194616 | 3 | 0 | Great: unmistakably a creepy koala. The first scary attempt (rbxassetid://78702348110149 / rbxassetid://102984468658933) was a flat-grey bear-ape with tiny ears. |
| snallygaster | Common | gaunt reptilian bird-dragon with a long sharp metallic silver beak, tattered leathery bat wings half spread, scaly grey-green body, thin tentacles dangling from under its beak, standing on two hooked bird feet, +STYLE | 3.4 x 3 x 3 | rbxassetid://94810624728859 | rbxassetid://140476442674641 | 3 | 0 | Good: bat-winged dragon with silver beak. 1st attempt failed (publish error). |
| gremlin | Common | small wiry hunched grey-green creature with huge tattered bat-like ears, oversized long-fingered hands, thin limbs, wide glowing yellow eyes, sly sinister smirk, wearing ragged mechanic overalls, holding a rusty wrench, +STYLE | 2.4 x 3 x 1.8 | rbxassetid://122939913645135 | rbxassetid://103548199248869 | 3 | 0 | Great. 1st attempt failed (play test running). |
| wolpertinger | Common | feral dark brown hare with ragged fur, small sharp antlers, tattered dark feathered wings folded on its back, hollow glowing amber eyes, crouching on its hind legs, +STYLE | 2.6 x 3 x 2.6 | rbxassetid://135528267883620 | rbxassetid://93241747302662 | 3 | 0 | Good: antlered winged hare. |
| chupacabra | Uncommon | gaunt hairless grey-green reptile-dog standing on four thin legs, a row of sharp quills down its spine, leathery mottled skin with visible ribs, sunken glowing red eyes, long thin tail, +STYLE | 2.2 x 3.6 x 4.4 | rbxassetid://130689751068861 | rbxassetid://83735307547478 | 3.6 | 0 | Excellent. |
| nightcrawler | Uncommon | eerie pale white cryptid made of only two parts: a big round smooth white head, and two extremely long thin stilt legs attached directly to the bottom of the head, absolutely no arms, no neck and no body, the head looks like a pale bulb on tall stilts, faint hollow glowing eyes, dark folklore cryptid, eerie and menacing, unsettling proportions, stylized low-poly game creature, full body, facing forward | 1.6 x 3.6 x 1.5 | rbxassetid://132300026238480 | rbxassetid://126215002906504 | 3.6 | 0 | Good: pale bulb head with red eyes on thin dark stilt legs. 1st scary attempt had a torso and arms (rejected). |
| loveland_frog | Uncommon | tall gaunt upright frog-man standing on two legs like a person, slimy mottled dark green skin, wide thin-lipped frog mouth, bulging glowing yellow eyes, long webbed fingers holding a crackling sparking wand, +STYLE | 2.2 x 3.6 x 1.8 | rbxassetid://112903869774176 | rbxassetid://113847998897304 | 3.6 | 0 | OK: tall gaunt frog-man with wand; brighter green and less dark than the others. |
| goatman | Uncommon | towering bipedal goat-man standing tall and upright like a person, gaunt human-like torso with two long thin arms hanging at its sides, two hoofed goat legs, goat head with long curling ram horns, dark matted shaggy brown fur, hollow glowing yellow eyes, +STYLE | 2 x 3.6 x 1.2 | rbxassetid://106004579622983 | rbxassetid://124830824690754 | 3.6 | 0 | Good. 1st scary attempt was a four-legged ram (rejected). |
| bray_road | Uncommon | hulking shaggy dark brown wolf-like cryptid standing upright on two bent hind legs, hunched heavy shoulders, long arms with long claws, pointed ears, long wolf snout, glowing yellow eyes, ragged matted fur, +STYLE | 2.8 x 3.6 x 2.2 | rbxassetid://80700709050180 | rbxassetid://77749288711735 | 3.6 | 0 | Excellent: hulking upright wolf. |
| squonk | Uncommon | pitiful hunched creature with loose sagging warty grey-pink skin hanging in heavy folds, small sunken weeping eyes with streaming tears, droopy pig-like snout, standing on four short legs, +STYLE | 2.4 x 3 x 3.2 | rbxassetid://130028451418667 | rbxassetid://128347868467618 | 3.6 | 0 | Good: saggy weeping pink creature (stands upright-ish, not on four legs). |
| yeti | Rare | towering hunched shaggy white-grey snow ape standing upright, very long heavy arms hanging to the ground, matted icy fur, dark grey-blue leathery face, deep-set glowing pale blue eyes, +STYLE | 3.2 x 4.4 x 2.4 | rbxassetid://71417033105011 | rbxassetid://81052759386079 | 4.4 | 0 | Good: hunched white ape, glowing blue eyes. |
| ogopogo | Rare | long dark green-black lake serpent with no legs, thick snake-like body coiled in loops and humps on the ground, long neck raised high, horse-like head with a ragged dark mane and small fins, +STYLE | 4.4 x 3.6 x 5 | rbxassetid://119501796851037 | rbxassetid://131581534909188 | 4.4 | 0 | Excellent: coiled serpent, raised horse-like head. Footprint ~4.6 x 4.6. |
| dover_demon | Rare | pale emaciated creature with a huge bulbous oversized egg-shaped head, blank glowing orange eyes with no pupils, no mouth, very long thin spindly arms and legs with long thin fingers, rough peach-grey skin, standing slightly hunched, +STYLE | 2.2 x 4.4 x 1.8 | rbxassetid://127820108357810 | rbxassetid://128404826249463 | 4.4 | 0 | Great. |
| flatwoods | Rare | towering eerie alien figure with a huge pointed spade-shaped dark hood rising behind its head, a round glowing red face with two bright glowing eyes, dark green pleated skirt-like metallic body flaring out to the ground, two small thin arms with long thin fingers, +STYLE | 2.6 x 4.4 x 2 | rbxassetid://95978287199268 | rbxassetid://114948872465345 | 4.4 | 0 | Good: pointed hood, red face, dark green pleated gown. |
| jersey_devil | Rare | gaunt kangaroo-like creature standing upright on two hooved hind legs, horse-like head with small curved horns, large tattered leathery bat wings spread wide, long thin tail with a forked tip, short thin arms, dark purple-brown hide, glowing red eyes, +STYLE | 4.4 x 4.4 x 3 | rbxassetid://133077204186004 | rbxassetid://112001839476144 | 4.4 | 0 | Good: winged horned upright creature; quite purple and dragon-like. |
| mothman | Epic | tall shadowy dark grey moth-man standing upright on two thin legs, huge tattered moth wings spread wide behind it, enormous glowing red eyes, thin dark body covered in fine grey fuzz, feathery antennae, +STYLE | 5.6 x 5.2 x 2.4 | rbxassetid://107438722643971 | rbxassetid://135727397672515 | 5.2 | 0 | Good. ~6 studs wingspan. |
| bigfoot | Epic | huge dark brown hulking sasquatch walking upright mid-stride, massive shoulders, long swinging arms, shaggy matted dark fur, big bare feet, deep-set glowing amber eyes in a dark leathery face, +STYLE | 3.6 x 5.2 x 3 | rbxassetid://124745552711970 | rbxassetid://89032616199124 | 5.2 | 0 | Good: hulking dark ape (standing, not mid-stride; gorilla-ish face). |
| thunderbird | Epic | massive storm-dark eagle-like bird perched upright, huge wings spread wide, dark blue-black feathers with glowing yellow lightning-bolt patterns, hooked beak, fierce glowing yellow eyes, sharp talons, +STYLE | 7 x 5.2 x 3.4 | rbxassetid://118963594307595 | rbxassetid://82598969794423 | 5.2 | 0 | Good. ~6.2 studs wingspan. |
| bunyip | Epic | dark tusked swamp creature crouching low on four flipper-like legs, dog-like face with long walrus tusks, wet matted dark green-brown fur hung with swamp weed, glowing green eyes, +STYLE | 3.6 x 3.4 x 5.2 | rbxassetid://113317298872835 | rbxassetid://123505522201560 | 5.2 | 0 | Good: mossy hulking tusked creature. |
| death_worm | Epic | huge fat bright red sand worm rearing up out of a thick coil on the ground, segmented glossy ridged body, a gaping round mouth at the top ringed with rows of soft rounded bumps, dark folklore cryptid, eerie and menacing, unsettling proportions, mottled dark textures, stylized low-poly game creature, full body, facing forward | 3.4 x 4.6 x 3.4 | rbxassetid://72402313990350 | rbxassetid://88869529137142 | 5.2 | 0 | Good: mouth faces -Z. |
| nessie | Legendary | dark green-black plesiosaur lying low on the ground, smooth rounded body with four wide paddle flippers spread flat, a single small head at the end of a very long curved neck raised high, long tapering tail, glowing eyes, ancient dark folklore cryptid, unsettling, mottled dark textures, stylized low-poly game creature, full body, facing forward | 4 x 5 x 8 | rbxassetid://105933576488987 | rbxassetid://115855645034356 | 4.4 | 0 | Good plesiosaur (4 flippers, one head) but not very scary. Height kept at 4.4 because it is long and low (~7 wide x 8.3 long in game). Attempt 1 had a second face painted on its chest; attempt 2 ("Loch Ness plesiosaur … marine reptile … eerie and menacing") failed moderation; attempt 3 failed once because a play test started, then succeeded. |
| kraken | Legendary | giant ancient dark purple-red octopus-squid resting on the ground, many thick curling tentacles spreading and rising around it, huge glowing yellow eyes, tall ridged bulbous mantle, mottled slimy skin, +STYLE | 6.4 x 5 x 6.4 | rbxassetid://72768183058923 | rbxassetid://137691239141461 | 6.2 | 0 | Good; more red than purple. ~7.3 studs wide. |
| ningen | Legendary | towering smooth pale white humanoid sea creature, featureless blank face with only two small black eyes, no nose and no mouth, very long thin arms hanging down past its knees, smooth rubbery pale skin, standing upright, dark folklore cryptid, eerie and menacing, gaunt unsettling proportions, mottled textures, stylized low-poly game creature, full body, facing forward | 3.4 x 6.2 x 2.4 | rbxassetid://117659548202346 | rbxassetid://83752095862825 | 6.2 | 0 | Good. |
| mokele_mbembe | Legendary | ancient dark olive-brown sauropod standing on four heavy elephant-like legs, long neck raised high, long heavy tail, small head with glowing eyes, rough mottled ridged hide, dark folklore cryptid, eerie and menacing, ancient, glowing eyes, mottled dark textures, stylized low-poly game creature, full body, facing forward | 3.4 x 6 x 8 | rbxassetid://120339522011118 | rbxassetid://84784757685916 | 6.2 | 0 | Good: olive sauropod, purple glowing eyes. ~7.6 studs long. 1st attempt failed (play test running). |
| the_static | Mythic (original) | tall gaunt humanoid figure whose whole body is made of flickering grey-white TV static noise, an old boxy CRT television set for a head with a glowing static-filled screen, long thin arms hanging down, standing perfectly still, deeply eerie, +STYLE | 3 x 6.4 x 2.4 | rbxassetid://95556272454043 | rbxassetid://78106021129534 | 6.4 | 0 | Good: static-textured gaunt body, wood-cased CRT head showing static. |
| the_signal | Mythic (original) | tall slender gaunt black metal humanoid figure with a large satellite dish for a head, three bright glowing cyan rings hovering horizontally around its chest, waist and knees, glowing cyan lines along its thin limbs, deeply eerie, +STYLE | 2.8 x 6.4 x 2.4 | rbxassetid://103819770144469 | rbxassetid://91451924433938 | 6.4 | 0 | Good: dark gaunt robot, dish head facing -Z, glowing cyan bands. Attempt 1 ("tall slender gaunt dark metal figure with a satellite radio dish for a head … glowing cyan rings floating around its thin body …" → rbxassetid://95786276064968 / rbxassetid://120256284504153) was grey with no visible cyan. |
| the_hollow | Mythic (original) | tall hooded figure made of dark twisted tree bark and drifting wisps of smoke, a faceless dark hood, a glowing purple hollow cavity in the middle of its chest, very long thin arms with branch-like fingers reaching down, deeply eerie, +STYLE | 3.4 x 6.4 x 2.6 | rbxassetid://88078350984363 | rbxassetid://125532570798335 | 6.4 | 0 | Good: bark hooded figure, glowing purple chest and eyes; stockier than asked (~4.6 wide in game). |
| redacted | Secret (original) | tall thin featureless pitch-black silhouette figure made of glitchy broken cubes and blocks, its edges breaking apart into floating black pixel cubes, two small glowing red eyes, long thin arms, standing still, deeply eerie, +STYLE | 2.8 x 6.4 x 2 | rbxassetid://120127131863803 | rbxassetid://108522663384059 | 6.4 | 0 | OK: tall thin dark blocky figure with red eyes (not very "glitchy"; the game draws it as a ForceField silhouette anyway). |

## Eggs (Config.Art.Eggs)

Every egg is one upright egg, `size` 2.6 x 3.4 x 2.6, `Height` 3.4. The lead
asked for eggs that read clearly as their tier from across a camp and feel
ominous, so each has its own colour and silhouette: forest = green + vines,
swamp = olive-brown + reeds/lily pads + oozing green crack, mountain = grey
stone + snow cap, deepsea = tall navy-blue + glowing cyan dots + coral,
sky = pale + wings + storm cloud, void = charcoal + magenta glow.

| id | final prompt | Mesh | Texture | Height | Yaw | notes |
|---|---|---|---|---|---|---|
| forest | a single large deep forest-green egg standing upright, the whole shell covered in thick dark green moss and lichen, wrapped in black thorny vines with a few dark green leaves, faint glowing green cracks, ominous cryptid egg, dark forest, stylized low-poly game item | rbxassetid://128755161420008 | rbxassetid://113316397783775 | 3.4 | 0 | Good/distinct: clearly green egg with dark vines and moss tufts. Attempt 1 ("a single large dark mossy green egg … wrapped tightly in black thorny vines and dead leaves …" → rbxassetid://77821843742221 / rbxassetid://115580597409385) was creepier but blue-grey, too close to mountain/deepsea. One regen attempt failed (play test). |
| swamp | a single large murky olive-brown egg standing upright, shell streaked with dripping black swamp mud and slimy algae, tangled dark reeds and a wilted lily pad clinging to it, sickly yellow-green glow leaking from deep cracks, ominous cryptid egg, dark swamp, stylized low-poly game item | rbxassetid://117946403371475 | rbxassetid://94687691990628 | 3.4 | 0 | Good: speckled olive egg with a glowing green crack oozing down, reeds and lily pads round the base (sits on a small mossy disc). Attempt 1 (rbxassetid://109419354523171 / rbxassetid://118733378237954: brown egg, mud cap with bright lily pads) was distinct but cute. |
| mountain | a single large jagged grey stone egg standing upright, rough rocky shell with deep cracks glowing icy pale blue, a thick snowy cap on top with hanging icicles, ominous cryptid egg, frozen mountain, stylized low-poly game item | rbxassetid://120477806906855 | rbxassetid://85325511736961 | 3.4 | 0 | Great: grey stone, glowing ice-blue cracks, snow cap with icicles. |
| deepsea | a single large dark navy-blue egg standing upright, shell crusted with barnacles and pale coral, rows of glowing cyan bioluminescent spots like eyes across the shell, thin dark tentacle-like seaweed wrapping around its base, ominous cryptid egg, deep dark sea, stylized low-poly game item | rbxassetid://87607024621959 | rbxassetid://94220551670754 | 3.4 | 0 | Good/distinct: taller, narrower deep-blue egg with rows of glowing cyan dots and orange coral round the base (~2.1 wide). Attempt 1 (rbxassetid://80467682038434 / rbxassetid://134360886378072: round royal-blue egg, barnacles + seaweed, faint cyan) was less ominous. |
| sky | a single large pale white and gold egg standing upright, two tattered grey feathered wings folded around its sides, swirling dark storm-cloud patterns on the shell, glowing golden lightning cracks, ominous cryptid egg, stormy sky, stylized low-poly game item | rbxassetid://128991196430590 | rbxassetid://80597578119558 | 3.4 | 0 | Good/distinct: pale egg with two grey wings and a dark storm cloud with a lightning crack on the front. Wings make it ~3.9 wide. |
| void | a single large pitch-black egg standing upright, glowing magenta veins and cracks running across the shell, tiny glowing stars visible deep inside the cracks, a few sharp black crystal shards floating around it, ominous cryptid egg, cosmic void, stylized low-poly game item | rbxassetid://107844197297365 | rbxassetid://92962855209984 | 3.4 | 0 | Good/distinct: charcoal egg with a wide jagged crack band glowing magenta. No floating shards. |

## Props (Config.Art.Props)

All props: suffix `stylized low-poly game asset, spooky night campsite`
(already included in the prompts below). Facing matters only for the
Tent (opening), Lantern, LogBench (seat) and Signpost (boards): all face -Z.

| id | final prompt | size | Mesh | Texture | Height | Yaw | notes |
|---|---|---|---|---|---|---|---|
| BroodMother | The Brood Mother: an extremely tall thin towering cryptid, much taller than wide, standing on long spindly spider-like legs, two long thin arms reaching forward, a cracked pale eggshell skull with one huge glowing yellow eye, a tattered dark moss and root cloak hanging from its narrow shoulders, hunched forward, eerie and menacing, dark folklore creature, stylized low-poly game creature, full body, facing forward | 8 x 16 x 7 | rbxassetid://82525672471592 | rbxassetid://92308619353136 | 16 | 0 | The night villain. Great: tall gaunt skeletal figure, pale cracked skull with one big yellow eye, tattered moss cloak, arms reaching forward; faces -Z; ~8.8 x 16 x 8.1 in game. Attempt 1 (the coordinator's prompt "The Brood Mother: a towering gaunt cryptid with long spindly spider-like limbs, a cracked pale eggshell skull with one huge glowing eye, a ragged cloak of dark moss and roots, hunched and reaching forward …", size 10 x 16 x 8 → rbxassetid://122075443636224 / rbxassetid://91754368707518) was squat (~12.7 wide) with a bright moss-green hood; fallback. |
| BroodNest | very wide flat low ring-shaped nest lying on the ground, like a giant bird nest, made of tangled black thorny branches and twisted dark roots, hollow empty bowl in the middle with a few small broken pale shell fragments, spooky dark forest game prop, stylized low-poly | 12 x 4 x 12 | rbxassetid://92051071995688 | rbxassetid://136342658450558 | 4 | 0 | Marks where the Brood Mother emerges. Good: big dark twisted-branch nest, ~11.3 x 11.1. Shell bits not really visible. Attempt 1 came back as a single egg (rbxassetid://84969945458288 / rbxassetid://115542294714880). |
| PineTree | very tall slender narrow pine tree, about four times taller than it is wide, tall straight dark brown trunk, narrow pointed conical crown of dark green needle branches, stylized low-poly game asset, spooky night campsite | 7 x 26 x 7 | rbxassetid://120978045480952 | rbxassetid://99906053858043 | 26 | 0 | Good; ~15 wide at height 26 (the generator never made it as slim as asked). Attempt 1 ("tall dark green pine tree …" → rbxassetid://74617840816157 / rbxassetid://139231092437379) was ~19.5 wide at height 26. One attempt failed (play test). |
| RoundTree | round leafy deciduous tree with a thick gnarled dark brown trunk and a big round dark green leafy canopy, stylized low-poly game asset, spooky night campsite | 14 x 18 x 14 | rbxassetid://137352084557648 | rbxassetid://73858969692287 | 18 | 0 | Good; ~16.4 wide. |
| Bush | round dense leafy dark green bush, clumps of leaves, stylized low-poly game asset, spooky night campsite | 4 x 3 x 4 | rbxassetid://113515846658272 | rbxassetid://82770608079115 | 3 | 0 | OK: cluster of round leafy balls. |
| Rock | small irregular grey rock lying on the ground, an angular flattened stone wider than it is tall with a few facets and cracks, small patches of green moss on top, stylized low-poly game asset, spooky night campsite | 4.4 x 3 x 3.8 | rbxassetid://104204045661071 | rbxassetid://134156184554572 | 3 | 0 | Good. Attempt 1 ("mossy grey rock, rounded lumpy stone …" → rbxassetid://100505084404021) looked like a barrel with a moss lid. |
| Boulder | big wide mossy grey boulder sitting on the ground, a massive rounded lumpy rock wider than it is tall, cracks and thick patches of green moss on top, stylized low-poly game asset, spooky night campsite | 10 x 7 x 9 | rbxassetid://122868846112775 | rbxassetid://138895984433120 | 6 | 0 | Good, flat-topped. Height set to 6 (not 7) so it is ~10.6 wide rather than 12.4. Attempt 1 ("big mossy grey boulder …" → rbxassetid://127824476248887) was a tall rock pillar. |
| Stump | cut tree stump with visible tree rings on the flat top, rough dark bark, a few roots spreading at the base, small patch of moss, stylized low-poly game asset, spooky night campsite | 3.4 x 2 x 3.4 | rbxassetid://77014346713469 | rbxassetid://93505119968562 | 2 | 0 | Great. |
| FallenLog | long fallen tree log lying on its side on the ground, rough dark bark, patches of green moss along the top, broken jagged ends, a few small mushrooms, stylized low-poly game asset, spooky night campsite | 2.4 x 2 x 9 | rbxassetid://119148576956714 | rbxassetid://75875174676139 | 2.4 | 0 | Good: mossy log with small red mushrooms; long axis is Z. Height 2.4 makes it ~7.6 long (at 2 it would be 6.3). |
| Mushroom | cluster of glowing teal mushrooms, several mushrooms of different heights with wide caps and pale stems, bioluminescent teal glow, growing from a small mossy mound, stylized low-poly game asset, spooky night campsite | 3 x 2.5 x 3 | rbxassetid://121976905947599 | rbxassetid://103288479519348 | 2.5 | 0 | Good: teal mushroom cluster on a mossy disc. |
| Tent | old canvas camping tent, A-frame shape, weathered olive-tan canvas with patches, front door flap tied open showing a dark inside, wooden poles and guy ropes pegged to the ground, stylized low-poly game asset, spooky night campsite | 10 x 7 x 10 | rbxassetid://113005939175837 | rbxassetid://121224824088418 | 7 | 0 | Good; opening faces -Z; ~11.3 wide. |
| Campfire | cold extinguished fire pit: a low ring of rough grey stones with three charred wooden logs lying flat and crossed inside on a bed of grey ash, cold and dark, flat and low to the ground, stylized low-poly game asset, spooky night campsite | 5 x 2 x 5 | rbxassetid://134781419754335 | rbxassetid://101049878330451 | 2.5 | 0 | Good: stone ring + crossed logs, no flame (the game adds fire); ~5.2 wide. Attempt 1 ("unlit campfire … no flames" → rbxassetid://109753008137228) had a baked flame mesh. |
| Lantern | tall weathered wooden lamp post with a short crossbar arm at the top, an old black iron lantern with glass panes hanging from the arm, warm amber glow inside, stylized low-poly game asset, spooky night campsite | 2.4 x 6 x 1.6 | rbxassetid://136230819142612 | rbxassetid://76117696975394 | 6 | 0 | Good. |
| LogBench | rustic log bench: a long half-split log with a flat seat on top resting on two short thick stump legs, rough dark bark on the sides, stylized low-poly game asset, spooky night campsite | 8 x 2.5 x 2.4 | rbxassetid://101656690216689 | rbxassetid://120458372602051 | 2.5 | 0 | OK: plank seat with a log backrest on stump legs, seat faces -Z. Only ~4.6 long (asked ~8). Attempt 2 ("long low rustic log bench with no backrest …" → rbxassetid://108711816708895 / rbxassetid://123097890850805) was ~6.2 long but oddly blue-grey wood. |
| Crate | old weathered wooden supply crate made of planks with dark iron corner brackets and a rope handle, scuffed and dusty, stylized low-poly game asset, spooky night campsite | 3 x 3 x 3 | rbxassetid://126832556889214 | rbxassetid://137093063646573 | 3 | 0 | Great. |
| Nest | very wide flat shallow bird nest lying on the ground, about four times wider than it is tall, a low thick ring of woven brown twigs and golden straw around a wide empty shallow hollow, stylized low-poly game asset, spooky night campsite | 6 x 1.6 x 6 | rbxassetid://84706038882341 | rbxassetid://97704595335257 | 1.6 | 0 | Good: ~6.1 wide. Attempt 1 ("big round empty bird nest …" → rbxassetid://133744806901262) was only ~3.7 wide at height 1.6. |
| Totem | very tall narrow carved wooden totem pole, about four times taller than it is wide, five stacked carved cryptid creature faces with hollow glowing eyes, painted in faded red, teal and black, small carved wings at the very top, weathered wood, stylized low-poly game asset, spooky night campsite | 3.4 x 14 x 3 | rbxassetid://80341899594440 | rbxassetid://136490453925914 | 14 | 0 | Good: tall dark totem with stacked faces, ~4.9 wide. Attempt 1 (rbxassetid://90477829662382) was stubby (~9.5 wide). |
| Signpost | weathered wooden signpost: one tall wooden post with three arrow-shaped plank signs pointing in different directions, faded blank boards, slightly crooked, stylized low-poly game asset, spooky night campsite | 4 x 7 x 3 | rbxassetid://105253205156519 | rbxassetid://133934530233307 | 7 | 0 | Good: three mossy arrow boards facing -Z. |

## Fallbacks (first-pass cute versions, not in Config)

Tested, working alternatives (all face -Z) if a scary version ever has to be
pulled. Prompts had the cute style suffix appended.

| id | Mesh | Texture | prompt |
|---|---|---|---|
| jackalope | rbxassetid://85352381854483 | rbxassetid://126240630760715 | earlier session; looks like a deer fawn with antlers |
| hodag | rbxassetid://85367518077839 | rbxassetid://84833785628759 | Hodag: stocky green-grey lizard-ox creature standing on all four legs, a row of soft rounded white spikes along its back, two short stubby horns, happy wide smiling mouth, thick tail |
| drop_bear | rbxassetid://126295934712209 | rbxassetid://87854060169353 | Drop bear: chunky grey koala-like bear with big fluffy round ears, sitting, playful happy expression, big black button nose |
| snallygaster | rbxassetid://75162470331578 | rbxassetid://106388185546211 | earlier session; teal baby dragon-bird |
| gremlin | rbxassetid://126254166850113 | rbxassetid://77580744760169 | small green creature with very big pointy ears, wearing tiny blue overalls, holding a little wrench in one hand, standing on two legs, mischievous friendly smile |
| wolpertinger | rbxassetid://127285193930721 | rbxassetid://133318505315869 | Wolpertinger: cute brown rabbit with long rabbit ears, small feathered duck wings on its back and tiny antlers on its head, sitting on its hind legs, fluffy white tail |
| chupacabra | rbxassetid://77598158866397 | rbxassetid://133474160538010 | lean grey-green scaly dog-like reptile creature standing on four legs, a row of soft rounded spines down its back, big round shiny red eyes, long thin tail |
| nightcrawler | rbxassetid://101246017221206 | rbxassetid://71519955101053 | cute white ghost-like figure that is just one big round white head sitting directly on top of two very long thin white legs, no arms, no torso, standing |
| loveland_frog | rbxassetid://126154941211801 | rbxassetid://99964174041185 | friendly green frog person standing upright on two legs like a human, wide frog mouth smiling, pale yellow belly, holding a small sparkly magic wand with a star tip in one hand |
| goatman | rbxassetid://86070644672594 | rbxassetid://112454518933258 | friendly bipedal goat-man standing tall and upright like a person, human-like torso with two arms at its sides, two hoofed goat legs, goat head with two big curved horns and a little beard, shaggy brown fur, gentle smile |
| bray_road | rbxassetid://116456523173836 | rbxassetid://126573875603869 | big shaggy dark brown wolf with thick grey-brown fur and a fluffy neck mane, standing on all four legs, pointed wolf ears, long wolf snout, bushy dark tail, glowing yellow eyes, playful friendly face |
| squonk | rbxassetid://109881875046428 | rbxassetid://106687326239355 | sad little pink-grey creature with loose baggy wrinkly skin covered in small round bumps, big teary watery eyes, pig-like snout, droopy ears, standing on four short legs |
| yeti | rbxassetid://121519804789094 | rbxassetid://93835743160949 | Yeti: big fluffy white furry snow ape standing upright on two legs, long arms, blue-grey face and hands, friendly smile |
| dover_demon | rbxassetid://76157789944032 | rbxassetid://85614001105241 | small thin peach-coloured alien-like creature with a huge oversized watermelon-shaped head, big round glowing orange eyes, long thin arms and long thin legs, standing upright, smooth skin (head came out as an actual watermelon) |
| flatwoods | rbxassetid://97294022037184 | rbxassetid://121890095693309 | tall friendly alien figure with a large pointed spade-shaped dark hood framing a round red face, two big round glowing eyes, a dark green pleated skirt-like cone body reaching the ground, two small short arms |
