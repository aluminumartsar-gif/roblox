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
| `size` | the size from the tables below (the bounding box the mesh is fitted into — mainly sets proportions; `Height` in Config does the final scaling) |
| `segmentation` | `"none"` (one MeshPart) |
| `maxTriangles` | `3500` |
| `async` | `true`, then poll `wait_job_finished` (a job takes ~3–6 minutes) |

The finished Model appears in Workspace, named after the prompt, with one
MeshPart whose `MeshID` / `TextureID` go into Config.

**Creature style suffix** (appended to every creature prompt; the tables say
`+STYLE` where it applies):

> dark folklore cryptid, eerie and menacing, gaunt unsettling proportions, glowing eyes, mottled dark textures, stylized low-poly game creature, full body, facing forward

The first pass used a cute style ("cute stylized low-poly cartoon game style,
chunky proportions, big friendly eyes, full body, facing forward"); the owner
switched the direction to scary ("cryptids are scary creatures"), so every
creature was regenerated. The cute ids are kept at the bottom of this file as
fallbacks.

### Lessons learned

- **Run at most 2 jobs at once.** Six at once → most failed.
- **Never generate during a play test.** A job started or finishing while
  Studio is in Play mode fails ("Model generation should only be called from
  the server" or "Failed to publish assets … PreviewAssets not found"). Retry
  once Studio is back in Edit.
- **Moderation**: avoid gore/violence words (blood, gore, kill, demon, devil,
  death, monster, fangs, teeth). Fine so far: eerie, menacing, gaunt,
  emaciated, hunched, towering, shadowy, ragged, feral, sharp spines,
  long claws, hollow glowing eyes, tattered wings, sinister. Describe
  the look rather than naming risky creatures (no "Jersey Devil", "Dover
  Demon", "Death Worm", "Loch Ness" in prompts).
- **Upright creatures**: "goat person standing upright" still produced a
  four-legged goat twice. What worked: "bipedal …-man standing tall and
  upright like a person, human-like torso with two arms at its sides".
- **Odd body plans** need it spelled out: the Fresno Nightcrawler only came
  out right with "made of only two parts: a big round head, and two long stilt
  legs attached directly to the bottom of the head, absolutely no arms, no
  neck and no body".
- Naming the creature can hurt: "Jackalope: …" produced a deer.
- The `size` aspect ratio is only a hint; e.g. a "wide nest" prompt once came
  back as a single egg. Always QA.

### How QA was done

Studio's viewport stopped rendering screenshots early in the session, so each
mesh was checked with a small software renderer instead: Luau in the Edit
datamodel loads the mesh and texture with `AssetService:CreateEditableMeshAsync`
/ `CreateEditableImageAsync`, rasterises a front view (camera on the -Z side)
and a 3/4 view with the texture, and the image was decoded and inspected. The
front view confirms the face points at -Z (with `Yaw` applied).

## Creatures (Config.Art.Creatures)

| id | rarity | final prompt | size | Mesh | Texture | Height | Yaw | notes |
|---|---|---|---|---|---|---|---|---|
| jackalope | Common | gaunt feral hare with long sharp branching antlers, long rabbit ears, hollow glowing yellow eyes, ragged grey-brown fur, crouching on its hind legs, +STYLE | 2 x 3 x 2.6 | rbxassetid://131681255958586 | rbxassetid://79054338605187 | 3 | 0 | Excellent: dark feral hare, long antlers, glowing eyes. |
| hodag | Common | hulking dark grey-green lizard-ox creature standing on four thick legs, heavy curved ox horns, a row of sharp white spines along its back and thick tail, broad fierce face, +STYLE | 2.8 x 3 x 4.4 | rbxassetid://112139235538943 | rbxassetid://111351156320288 | 3 | 0 | Good: horned green lizard-beast with back spines (more gaunt than hulking). |
| drop_bear | Common | hunched ragged grey koala-like predator with matted fur, long thin arms ending in long hooked claws, pale glowing white eyes, large tattered round ears, crouching, +STYLE | 2.6 x 3 x 2.6 | rbxassetid://78702348110149 | rbxassetid://102984468658933 | 3 | 0 | OK/weak: hunched grey bear-ape with claws; flat grey texture, koala ears small. Candidate for a regen. |
| snallygaster | Common | gaunt reptilian bird-dragon with a long sharp metallic silver beak, tattered leathery bat wings half spread, scaly grey-green body, thin tentacles dangling from under its beak, standing on two hooked bird feet, +STYLE | 3.4 x 3 x 3 | rbxassetid://94810624728859 | rbxassetid://140476442674641 | 3 | 0 | Good: bat-winged dragon with silver beak. 1st attempt failed (play test running). |
| gremlin | Common | small wiry hunched grey-green creature with huge tattered bat-like ears, oversized long-fingered hands, thin limbs, wide glowing yellow eyes, sly sinister smirk, wearing ragged mechanic overalls, holding a rusty wrench, +STYLE | 2.4 x 3 x 1.8 | rbxassetid://122939913645135 | rbxassetid://103548199248869 | 3 | 0 | Great. 1st attempt failed (play test running). |
| wolpertinger | Common | feral dark brown hare with ragged fur, small sharp antlers, tattered dark feathered wings folded on its back, hollow glowing amber eyes, crouching on its hind legs, +STYLE | 2.6 x 3 x 2.6 | rbxassetid://135528267883620 | rbxassetid://93241747302662 | 3 | 0 | Good: antlered winged hare. |
| chupacabra | Uncommon | gaunt hairless grey-green reptile-dog standing on four thin legs, a row of sharp quills down its spine, leathery mottled skin with visible ribs, sunken glowing red eyes, long thin tail, +STYLE | 2.2 x 3.6 x 4.4 | rbxassetid://130689751068861 | rbxassetid://83735307547478 | 3.6 | 0 | Excellent. |
| nightcrawler | Uncommon | eerie pale white cryptid made of only two parts: a big round smooth white head, and two extremely long thin stilt legs attached directly to the bottom of the head, absolutely no arms, no neck and no body, the head looks like a pale bulb on tall stilts, faint hollow glowing eyes, dark folklore cryptid, eerie and menacing, unsettling proportions, stylized low-poly game creature, full body, facing forward | 1.6 x 3.6 x 1.5 | rbxassetid://132300026238480 | rbxassetid://126215002906504 | 3.6 | 0 | Good: pale bulb head with red eyes on thin dark stilt legs. 1st scary attempt had a torso and arms (rejected). |
| loveland_frog | Uncommon | tall gaunt upright frog-man standing on two legs like a person, slimy mottled dark green skin, wide thin-lipped frog mouth, bulging glowing yellow eyes, long webbed fingers holding a crackling sparking wand, +STYLE | 2.2 x 3.6 x 1.8 | rbxassetid://112903869774176 | rbxassetid://113847998897304 | 3.6 | 0 | OK: tall gaunt frog-man with wand; brighter green than asked. |
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
| the_signal | Mythic (original) | tall slender gaunt dark metal figure with a satellite radio dish for a head, a thin antenna sticking up from the dish, glowing cyan rings floating around its thin body, long thin limbs, eerie cyan glow, deeply eerie, +STYLE | 2.8 x 6.4 x 2.4 | rbxassetid://95786276064968 | rbxassetid://120256284504153 | 6.4 | 0 | OK: thin grey robot with a dish head (dish faces -Z). The cyan rings and glow did not come through — candidate for a regen. |
| the_hollow | Mythic (original) | tall hooded figure made of dark twisted tree bark and drifting wisps of smoke, a faceless dark hood, a glowing purple hollow cavity in the middle of its chest, very long thin arms with branch-like fingers reaching down, deeply eerie, +STYLE | 3.4 x 6.4 x 2.6 | rbxassetid://88078350984363 | rbxassetid://125532570798335 | 6.4 | 0 | Good: bark hooded figure, glowing purple chest and eyes; stockier than asked (~4.6 wide in game). |
| redacted | Secret (original) | tall thin featureless pitch-black silhouette figure made of glitchy broken cubes and blocks, its edges breaking apart into floating black pixel cubes, two small glowing red eyes, long thin arms, standing still, deeply eerie, +STYLE | 2.8 x 6.4 x 2 | rbxassetid://120127131863803 | rbxassetid://108522663384059 | 6.4 | 0 | OK: tall thin dark blocky figure with red eyes (not very "glitchy"; the game draws it as a ForceField silhouette anyway). |

## The Brood Mother (Config.Art.Props)

| id | final prompt | size | Mesh | Texture | Height | Yaw | notes |
|---|---|---|---|---|---|---|---|
| BroodMother | The Brood Mother: an extremely tall thin towering cryptid, much taller than wide, standing on long spindly spider-like legs, two long thin arms reaching forward, a cracked pale eggshell skull with one huge glowing yellow eye, a tattered dark moss and root cloak hanging from its narrow shoulders, hunched forward, eerie and menacing, dark folklore creature, stylized low-poly game creature, full body, facing forward | 8 x 16 x 7 | rbxassetid://82525672471592 | rbxassetid://92308619353136 | 16 | 0 | Great: tall gaunt skeletal figure, pale cracked skull with one big yellow eye, tattered moss cloak, arms reaching forward. Faces -Z. ~8.8 x 16 x 8.1 studs in game. Attempt 1 (the coordinator's prompt, size 10 x 16 x 8 → rbxassetid://122075443636224 / rbxassetid://91754368707518) was squat (~12.7 wide at height 16) with a bright moss-green hood; kept as a fallback. |
| BroodNest | very wide flat low ring-shaped nest lying on the ground, like a giant bird nest, made of tangled black thorny branches and twisted dark roots, hollow empty bowl in the middle with a few small broken pale shell fragments, spooky dark forest game prop, stylized low-poly | 12 x 4 x 12 | rbxassetid://92051071995688 | rbxassetid://136342658450558 | 4 | 0 | Good: big dark twisted-branch nest, ~11.3 x 11.1 wide. Shell bits not really visible. Attempt 1 came back as a single egg (rbxassetid://84969945458288 / rbxassetid://115542294714880). |

## Eggs (Config.Art.Eggs)

Every egg is one upright egg, `size` 2.6 x 3.4 x 2.6, `Height` 3.4. The lead
asked for eggs that read clearly as their tier from across a camp and feel
ominous, so each has its own colour and silhouette: forest = vines/leaves,
swamp = mud cap + lily pads, mountain = stone + snow cap, deepsea = blue +
barnacle/coral base, sky = wings, void = black + magenta glow.

| id | final prompt | Mesh | Texture | Height | Yaw | notes |
|---|---|---|---|---|---|---|
| forest | a single large deep forest-green egg standing upright, the whole shell covered in thick dark green moss and lichen, wrapped in black thorny vines with a few dark green leaves, faint glowing green cracks, ominous cryptid egg, dark forest, stylized low-poly game item | rbxassetid://128755161420008 | rbxassetid://113316397783775 | 3.4 | 0 | Good/distinct: clearly green egg with dark vines and moss tufts. Attempt 1 ("a single large dark mossy green egg … wrapped tightly in black thorny vines and dead leaves …" → rbxassetid://77821843742221 / rbxassetid://115580597409385) was creepier but blue-grey, too close to the mountain/deepsea colours. One regen attempt failed because a play test started. |
| swamp | a single large murky brown-green speckled egg standing upright, dripping with thick black swamp mud, a rotting lily pad and a few reeds stuck to its top, sickly yellow-green glow seeping from small cracks, ominous cryptid egg, dark swamp, stylized low-poly game item | rbxassetid://109419354523171 | rbxassetid://118733378237954 | 3.4 | 0 | Good/distinct: brown egg with a jagged crack band, mud cap with three bright lily pads. More earthy than ominous. |
| mountain | a single large jagged grey stone egg standing upright, rough rocky shell with deep cracks glowing icy pale blue, a thick snowy cap on top with hanging icicles, ominous cryptid egg, frozen mountain, stylized low-poly game item | rbxassetid://120477806906855 | rbxassetid://85325511736961 | 3.4 | 0 | Great: grey stone, glowing ice-blue cracks, snow cap with icicles. |
| deepsea | a single large deep ocean-blue egg standing upright, crusted with barnacles and small branching coral growths, glowing cyan bioluminescent spots across the shell, a few short seaweed fronds trailing from the base, ominous cryptid egg, deep sea, stylized low-poly game item | rbxassetid://80467682038434 | rbxassetid://134360886378072 | 3.4 | 0 | OK/distinct: strong royal blue, barnacles + coral + seaweed round the base; cyan spots are faint. |
| sky | a single large pale white and gold egg standing upright, two tattered grey feathered wings folded around its sides, swirling dark storm-cloud patterns on the shell, glowing golden lightning cracks, ominous cryptid egg, stormy sky, stylized low-poly game item | rbxassetid://128991196430590 | rbxassetid://80597578119558 | 3.4 | 0 | Good/distinct: pale egg with two grey wings and a dark storm cloud with a lightning crack on the front. Wings make it ~3.9 wide. |
| void | a single large pitch-black egg standing upright, glowing magenta veins and cracks running across the shell, tiny glowing stars visible deep inside the cracks, a few sharp black crystal shards floating around it, ominous cryptid egg, cosmic void, stylized low-poly game item | rbxassetid://107844197297365 | rbxassetid://92962855209984 | 3.4 | 0 | Good/distinct: charcoal egg with a wide jagged crack band glowing magenta. No floating shards. |

## Fallbacks (first-pass cute versions, not in Config)

If a scary version ever has to be pulled, these are tested, working
alternatives (all face -Z):

| id | Mesh | Texture | prompt (+ cute style) |
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
