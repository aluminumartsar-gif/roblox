-- World-space leaderboard models under Workspace and their OrderedDataStores.

local LeaderboardConfig = {}

LeaderboardConfig.WORKSPACE_FOLDER_NAME = "Leaderboards"
LeaderboardConfig.BRAINROT_MODEL_NAME = "LeaderboardBrainrot"
LeaderboardConfig.REBIRTH_MODEL_NAME = "LeaderboardRebirth"

LeaderboardConfig.DUMMY_NAMES = { "Dummy1", "Dummy2", "Dummy3" }

-- OrderedDataStore values are int64; Luau numbers are doubles — stay within 2^53.
LeaderboardConfig.MAX_ORDERED_SCORE = 9007199254740991

LeaderboardConfig.ORDERED_STORE_BRAINROT_RNG = "BrainrotRngRare_v3"
LeaderboardConfig.ORDERED_STORE_REBIRTH = "RebirthCount_v3"

LeaderboardConfig.POLL_INTERVAL_SEC = 45

-- Entries to show in the scrolling list / podiums slice (globally ranked, cross-server).
LeaderboardConfig.MAX_LEADERBOARD_LIST_ENTRIES = 200

-- How many keys we request per `GetSortedAsync` page (ODS max typically 100 per page).
LeaderboardConfig.ODS_PAGE_FETCH_SIZE = 100

-- List row layout — scale-based heights + AutomaticCanvasSize on SurfaceGui lists collapse rows and
-- shrink TextScaled labels; clamp rows and text for readable world UI.
LeaderboardConfig.LIST_ROW_FIXED_HEIGHT_PX = 56
LeaderboardConfig.LIST_ROW_MIN_TEXT_SIZE = 22

-- Extra pixels under the stacked rows so the ScrollingFrame canvas is taller than the window when needed.

LeaderboardConfig.LIST_SCROLL_VERTICAL_PADDING_PX = 28

-- Path relative to leaderboard model root (main list board only; TopPart title bar is not scripted).
LeaderboardConfig.BOARD_GUI_PATH_BOARD = "BoardModel/BoardBase/Leaderboard"

LeaderboardConfig.TIMER_PART_NAME = "Timer"
LeaderboardConfig.TIMER_GUI_CHILD_NAME = "GUI"
LeaderboardConfig.TIMER_LABEL_CHILD_NAME = "Label"

return LeaderboardConfig