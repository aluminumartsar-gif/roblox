---
name: roblox-luau-standards
description: >-
  Event-driven modular component architecture standards and Luau best practices
  for this Roblox codebase. Use when creating new modules, services,
  controllers, systems, or any Luau code. Always follow these conventions for
  consistency. For pure formatting/whitespace/naming rules see the
  `luau-style-guide` skill.
---

# Luau Architecture Standards

> **Formatting & style note.** This skill covers architecture decisions
> (modules, classes, signals, replication, error handling). For pure layout,
> indentation, requires ordering, naming conventions, `if-then-else`, table
> formatting, comments, and similar rules, use the `luau-style-guide` skill.

## Core Principle: Event-Driven Modular Components

Every module should be a self-contained component that communicates through
signals and events, never by reaching into another module's internal state.

Rules:

- Modules expose `Signal` instances for outbound events; consumers connect with
  `:Connect()`.
- Modules subscribe to other modules' signals or `QuestClientState.OnChange`
  style callbacks for inbound events.
- No module should directly mutate another module's state.
- Controllers never reference other controllers; route through a service or
  signal.

```luau
-- Good: service emits signal, controllers subscribe independently
local MyService = {}
MyService.SomethingHappened = Signal.New() -- fires (data)

-- In another module:
MyService.SomethingHappened:Connect(function(data)
    -- react to it
end)

-- Bad: controller A calls controller B directly
ControllerA.doSomething()
```

## Shared Utility Principle

Before writing any new helper function, search the entire codebase for existing
code that already solves the problem. Do not limit the search to utility folders;
check controllers, systems, and services for inline helpers too.

- If the logic exists in a shared location, require and use it directly.
- If it exists as a local function inside another module and would be useful
  elsewhere, extract it into a shared utility module.
- If the same pattern appears in two or more modules, consolidate it into one
  shared module.
- Place cross-boundary utilities in `ReplicatedStorage/Shared/Utility/`.
- Place client-only UI helpers in `StarterPlayerScripts/Client/UI/`.

Key existing shared utilities:

| Module | Location | What it provides |
| --- | --- | --- |
| `Signal` | `Shared/Utility/Signal` | Event pub/sub (`:Connect`, `:Fire`, `:Wait`) |
| `FormatUtils` | `Shared/Utility/FormatUtils` | Number formatting and string helpers |
| `Logger` | `Shared/Utility/Logger` | Structured logging (`Logger.new("Tag")`) |
| `Remote` | `Shared/Utility/Remote` | `Remote.New(name, unreliable?)` for network events |
| `ConfettiEffects` | `Shared/Utility/ConfettiEffects` | Screen-space and world-space confetti |
| `UIAnimations` | `Client/UI/UIAnimations` | Blur, shine, sparkle, vignette, and button animations |
| `UIService` | `Client/UI/UIService` | Sound links, fullscreen scaffolding, and hover tweens |
| `SoundHandler` | `Shared/Modules/SoundHandler` | `PlaySound` and `PlaySoundAtCFrame` |

## Module Structure Conventions

### Services

Services own data and logic, not UI.

- Location: `Client/Services/` or `Server/Services/`
- Expose signals and query functions.
- Subscribe to replica changes or other services.
- Examples: `QuestClientState`, `TutorialOnboardingService`

### Controllers

Controllers own UI rendering.

- Location: `Client/UI/Controllers/`
- Own a `ScreenGui`, create and manage UI instances.
- Subscribe to service signals for data; never fetch data themselves.
- Return a module table with public API such as `Show`, `Hide`, and `Refresh`.
- Examples: `QuestPanelController`, `NotificationGuiController`

### Systems

Systems own gameplay coordination and mechanics.

- Location: `Client/Systems/` or `Server/Systems/`
- Coordinate between multiple services or manage game mechanics.
- May own world-space instances such as billboards and effects.
- Examples: `HomeBlockRenderer`, `MiningSystem`

### Bootstrap

Bootstrap files wire modules together.

- `ClientBootstrap.client.luau` and `ServerBootstrap.server.luau` require modules
  for side-effect initialization.
- Require services before controllers so signals exist before subscribers
  connect.
- Call `ReplicaClient.RequestData()` last on the client.

## Signal Usage

Create module-level signals for outbound events and document what each signal
fires.

```luau
local Signal = require(Shared.Utility.Signal)

local MyModule = {}

MyModule.SomethingChanged = Signal.New() -- fires (id, newValue)

function MyModule.SetSomething(id: string, newValue: number)
    -- update local owned state
    MyModule.SomethingChanged:Fire(id, newValue)
end

return MyModule
```

Prefer signal subscriptions over polling. Clean up connections when instances,
controllers, or temporary flows are destroyed.

## Replication And Networking

- Treat server state as authoritative.
- Use shared remotes through `Shared/Utility/Remote` instead of ad hoc
  `RemoteEvent` lookup code.
- Validate all client-provided input on the server.
- Keep remote payloads explicit and stable.
- Prefer service-level APIs for network orchestration; UI controllers should
  request actions through services rather than owning remote details.

```luau
local Remote = require(Shared.Utility.Remote)

local PurchaseItem = Remote.New("PurchaseItem")

PurchaseItem:FireServer(itemId)
```

## Error Handling And Logging

- Use `Logger.new("Tag")` for structured logs instead of raw `print` statements.
- Avoid swallowing errors silently; surface unexpected states with useful
  context.
- Use `warn` or logger warnings for recoverable issues.
- Validate invariants close to the boundary where invalid data enters.

```luau
local Logger = require(Shared.Utility.Logger)

local log = Logger.new("InventoryService")

if itemConfig == nil then
    log:Warn("Missing item config", itemId)
    return false
end
```

## State Ownership

- Each module owns its own state and exposes query functions for read access.
- Other modules must not mutate owned tables directly.
- Return snapshots or read-only values when exposing state.
- Prefer small, intention-revealing functions over broad state accessors.

```luau
function QuestClientState.GetQuestProgress(questId: string): number?
    local quest = questsById[questId]
    return if quest then quest.progress else nil
end
```

## UI Architecture

- UI controllers render from service state and subscribe to service signals.
- Keep UI instance creation and styling inside controllers or shared UI helpers.
- Use `Client/UI/UIAnimations` and `Client/UI/UIService` before creating new UI
  animation helpers.
- UI controllers may expose `Show`, `Hide`, `Refresh`, or focused public methods,
  but should not be dependency hubs for other controllers.

## Class-Like Modules

Use class-like modules when a component has multiple instances with independent
lifecycle or state. Keep constructors small and explicit.

```luau
local Widget = {}
Widget.__index = Widget

export type Widget = typeof(setmetatable({} :: {
    _maid: any,
    _isVisible: boolean,
}, Widget))

function Widget.new(): Widget
    local self = setmetatable({
        _maid = {},
        _isVisible = false,
    }, Widget)

    return self
end

function Widget.Destroy(self: Widget)
    -- disconnect listeners and destroy instances
end

return Widget
```

## Lifecycle And Cleanup

- Any module that creates connections, tweens, threads, or instances must define
  where they are cleaned up.
- Prefer explicit `Destroy` methods for instance-like objects.
- Keep long-lived services/controllers initialized by bootstrap idempotent where
  practical.
- Avoid leaving `task.spawn`, `task.delay`, or event connections with no owner.

## Type Annotations

- Use Luau types for public APIs, network payloads, exported records, and complex
  state.
- Keep type definitions near the module that owns the data.
- Export types that cross module boundaries.

```luau
export type QuestState = {
    id: string,
    progress: number,
    goal: number,
    isComplete: boolean,
}
```

## Dependency Direction

- Shared utilities may be required by client and server code.
- Services may depend on shared utilities and other services when needed.
- Controllers depend on services and shared/client UI utilities.
- Controllers must not depend on other controllers.
- Server systems should not require client modules.
- Client modules should not require server modules.

## New Code Checklist

Before adding or changing Luau code:

1. Search for an existing utility or pattern that already solves the problem.
2. Decide whether the code is a service, controller, system, shared utility, or
   bootstrap concern.
3. Expose outbound events with `Signal` when other modules need to react.
4. Subscribe to data changes instead of polling or reaching into another module.
5. Keep state ownership clear and avoid direct cross-module mutation.
6. Use existing `Remote`, `Logger`, `FormatUtils`, UI, sound, and effects helpers
   before adding new ones.
7. Add focused tests or verification when behavior is shared, user-facing, or
   high risk.
