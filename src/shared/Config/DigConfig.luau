local DigConfig = {
	TOOL_NAME = "Basic Shovel",
	REMOTE_FOLDER = "BrainrotRemotes",
	DIG_REQUEST_REMOTE = "DigRequestV2",
	DIG_STARTED_REMOTE = "DigStartedV2",
	DIG_REJECTED_REMOTE = "DigRejectedV2",
	DIG_STOP_REMOTE = "DigStopRequestV1",
	DIG_CLAIM_REMOTE = "DigClaimV1",
	DIG_MISS_REMOTE = "DigMissV1",
	DIG_STATE_REMOTE = "DigStateV1",
	DIG_BROKEN_REMOTE = "DigBrokenV1",
	-- Fired by the server the moment a fresh dig request transitions into the
	-- countdown phase. Payload carries { duration, position, phase } so the
	-- client can render the countdown ring + CANCEL UI in the right spot.
	-- Resolved by the existing dig-state echo when the countdown completes.
	DIG_COUNTDOWN_STARTED_REMOTE = "DigCountdownStartedV1",
	DIG_SITE_ENTERED_REMOTE = "DigSiteEnteredV1",
	DIG_SITE_LEFT_REMOTE = "DigSiteLeftV1",
	BRAINROT_SPAWNED_REMOTE = "BrainrotSpawned",
	BRAINROT_COLLECTED_REMOTE = "BrainrotCollected",

	-- Weather subsystem remotes. Folder is kept distinct from the dig
	-- BrainrotRemotes folder so weather replication is decoupled from the
	-- per-dig signal storm during commit/break.
	WEATHER_REMOTE_FOLDER = "WeatherRemotes",
	WEATHER_STARTED_REMOTE = "WeatherStartedV1",
	WEATHER_ENDED_REMOTE = "WeatherEndedV1",
	WEATHER_SYNC_REMOTE = "WeatherSyncV1",

	BRAINROT_DESPAWN_REMOTE = "BrainrotDespawn",
	PICKUP_PROMPT_HOLD_DURATION = 0.8,
	PICKUP_PROMPT_MAX_DISTANCE = 10,

	-- One swing per dig: the player clicks once, the brainrot's silhouette
	-- rises with full odds + rarity, and they choose KEEP BRAINROT (claim)
	-- or KEEP DIGGING (risky reroll for boosted luck). Anything beyond
	-- this first swing is treated as the EXTRA / snap-risk phase by
	-- DigService.handleDig. See ShovelConfig: every tier now has
	-- requiredHits = 1 so this fallback rarely fires.
	DIG_REQUIRED_HITS = 1,
	DIG_HIT_DURATION = 0.38,
	DIG_HIT_COOLDOWN = 0,
	-- Hard floor on the per-dig countdown duration: the shovel's digDuration
	-- multiplied by ShovelUpgradeConfig.getDigDurationMultiplier is clamped
	-- above this so heavily-upgraded players still see a brief dig animation
	-- play before the brainrot reveal. 0.3s is roughly one full windup→thrust.
	DIG_COUNTDOWN_MIN_DURATION = 0.3,
	-- Click mode keeps a session alive indefinitely between clicks; the player
	-- ends a dig with PULL UP, CANCEL, or by walking off the dig site. Chain
	-- timeout is kept as a safety net only, so set it high enough to not
	-- interrupt thinking time at the claim-or-risk decision.
	DIG_CHAIN_TIMEOUT = 600,
	-- Hard cap on how long a single dig session can stay open from first
	-- swing to claim. When this expires the session is auto-terminated and
	-- the spot is marked dug so the player can't camp the same hole.
	DIG_SESSION_TIMEOUT = 30,
	DIG_REVEAL_DELAY = 0.45,
	DIG_COOLDOWN = 0.9,
	MAX_DIG_DISTANCE = 16,
	DIG_FORWARD_DISTANCE = 5,
	SPAWN_RISE_DEPTH = 7,
	SPAWN_RISE_TIME = 1.1,
	AUTO_COLLECT_DELAY = 1.5,
	COLLECT_FLY_TIME = 0.85,
	DROP_LIFETIME = 20,
	DESPAWN_ANIM_DURATION = 0.7,

	-- Deep-dig (risk/reward) phase. After the standard DIG_REQUIRED_HITS the
	-- player can keep clicking to risk extra hits with no upper bound. The
	-- break chance climbs linearly per the curve below (first extra is 10%,
	-- second 20%, third 30%, etc., capped at 100%) and luck multiplies the
	-- session baseline per survived extra hit (see EXTRA_HIT_LUCK_MULT). A
	-- break forfeits this dig only.
	EXTRA_HIT_BREAK_PER_HIT = 0.1,
	-- Per successful deep hit: effective luck = baselineLuck * (MULT ^ extraHits).
	EXTRA_HIT_LUCK_MULT = 1.12,
	BREAK_COOLDOWN = 1.5,

	-- Friend boost: each friend of the digging player who is currently in the
	-- server adds this fraction to a flat additive multiplier on top of the
	-- baseline luck. 0.05 = +5% per friend (e.g. 3 friends → ×1.15).
	FRIEND_LUCK_PER_FRIEND = 0.05,

	-- Click mode: how far from the player's HumanoidRootPart a click on the
	-- dig floor is allowed to land. Server still re-validates with
	-- MAX_DIG_DISTANCE; this just keeps clients from spamming requests for
	-- absurd targets.
	DIG_CLICK_MAX_DISTANCE = 24,

	-- Timing bar QTE. Cursor crossing time starts at BASE_SPEED seconds; each
	-- survived extra hit multiplies duration by CURSOR_DECAY_MULT (<1 → faster
	-- sweep), floored at MIN_DURATION. Green zone width starts at
	-- BASE_GREEN_SIZE and multiplies by GREEN_DECAY_MULT per extra hit,
	-- floored at MIN_GREEN_SIZE so difficulty keeps scaling instead of hitting
	-- an early plateau. GREEN_PADDING keeps the zone from spawning at the edges.
	TIMING_BAR_BASE_SPEED         = 1.7,
	TIMING_BAR_CURSOR_DECAY_MULT = 0.86,
	TIMING_BAR_MIN_DURATION       = 0.22,
	TIMING_BAR_BASE_GREEN_SIZE    = 0.17,
	TIMING_BAR_GREEN_DECAY_MULT   = 0.9,
	TIMING_BAR_MIN_GREEN_SIZE     = 0.018,
	TIMING_BAR_GREEN_PADDING      = 0.06,
}

return DigConfig
