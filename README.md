# MacLib

![License](https://img.shields.io/badge/license-CC0--1.0-blue)

A clean, sleek macOS-flavoured UI library for Roblox. Single file, no dependencies, no assets to upload.

```lua
local MacLib = loadstring(game:HttpGet("https://raw.githubusercontent.com/JSWorth/Maclib/main/main.lua"))()
```

- Traffic-light window chrome, draggable and resizable, with a background blur
- Sidebar tab groups and macOS *System Settings* style grouped cards
- Dark and Light themes with a live runtime switch
- Real [Solar](https://solar-icons.vercel.app) icons, fetched and rasterised at runtime — no pre-uploaded decals
- Toggles, sliders, dropdowns (single and multi), inputs, keybinds, buttons, paragraphs, labels, dividers
- Toast notifications, modal alert sheets and a first-run changelog card
- A built-in settings tab whose preferences follow the user across every script
- Flag-based config saving and loading
- A self-test that reports what actually works in the current environment

---

## Contents

- [Quick start](#quick-start)
- [Window](#window)
- [Tabs and sections](#tabs-and-sections)
- [Elements](#elements)
- [Notifications and dialogs](#notifications-and-dialogs)
- [Settings tab](#settings-tab)
- [Changelog card](#changelog-card)
- [Flags and configs](#flags-and-configs)
- [Theming](#theming)
- [Icons](#icons)
- [Support badge](#support-badge)
- [Environment support](#environment-support)
- [Credits](#credits)

---

## Quick start

```lua
local MacLib = loadstring(game:HttpGet("https://raw.githubusercontent.com/JSWorth/Maclib/main/main.lua"))()

local Window = MacLib:Window({
    Title    = "Aurora",
    Subtitle = "v1.0.0",
    Size     = UDim2.fromOffset(780, 500),
    Theme    = "Dark",
    Accent   = Color3.fromRGB(10, 132, 255),
})

local Main = Window:TabSection("General")
local Home = Main:Tab({ Title = "Home", Icon = "home-2" })

local Section = Home:Section({ Title = "Movement" })

Section:Toggle({
    Title   = "Infinite jump",
    Default = false,
    Flag    = "player.infjump",
    Callback = function(state) print(state) end,
})

Section:Slider({
    Title = "Walk speed",
    Min = 16, Max = 250, Default = 16, Suffix = " studs/s",
    Callback = function(v)
        local hum = game.Players.LocalPlayer.Character
            and game.Players.LocalPlayer.Character:FindFirstChildWhichIsA("Humanoid")
        if hum then hum.WalkSpeed = v end
    end,
})

Window:Notify({ Title = "Loaded", Description = "Right Shift toggles the UI.", Icon = "rocket" })
```

A full example covering every element lives at the bottom of `main.lua`, inside a comment block.

---

## Window

```lua
local Window = MacLib:Window({
    Title      = "Aurora",                        -- title bar text
    Subtitle   = "v1.0.0  •  Universal",          -- smaller line beneath it
    Size       = UDim2.fromOffset(780, 500),      -- UDim2 or Vector2
    Theme      = "Dark",                          -- "Dark" | "Light"
    Accent     = Color3.fromRGB(10, 132, 255),    -- selection / control colour
    IconStyle  = "outline",                       -- default Solar weight
    ToggleKey  = Enum.KeyCode.RightShift,         -- show / hide the window
    Folder     = "Aurora",                        -- where configs are written
    Blur       = true,                            -- background blur while open
    Changelog  = true,                            -- show the changelog card on first run
})
```

`Style` is accepted as an alias for `IconStyle`, `Keybind` for `ToggleKey`, and `ConfigFolder` for `Folder`.

| Method | Description |
| --- | --- |
| `Window:Toggle()` | Show or hide the window |
| `Window:SetOpen(state, instant)` | Explicit show/hide; `instant` skips the animation |
| `Window:Minimize()` | Collapse to the floating chip |
| `Window:Restore()` | Bring a minimised window back |
| `Window:Maximize()` | Toggle between the set size and ~92% of the viewport |
| `Window:SetTitle(title, subtitle)` | Update the title bar |
| `Window:SetTheme(name)` | `"Dark"` or `"Light"` |
| `Window:Unload()` | Destroy the UI and disconnect everything (`Window:Destroy()` is an alias) |

Useful fields: `Window.Gui`, `Window.Tabs`, `Window.Flags`, `Window.Values`, `Window.Open`, `Window.Minimized`, `Window.Maximized`, `Window.ToggleKey`.

The traffic lights map to red = unload, yellow = minimise, green = maximise. Drag the title bar to move; drag the icon in the bottom-right corner to resize.

---

## Tabs and sections

```lua
local Group = Window:TabSection("General")        -- sidebar heading
local Tab   = Group:Tab({ Title = "Home", Icon = "home-2" })
local Sect  = Tab:Section({ Title = "Movement", Description = "Optional footnote" })
```

`Window:Tab({...})` also works directly if you do not want a heading. `TabGroup` is an alias for `TabSection`, and `Groupbox` for `Section`.

| Method | Description |
| --- | --- |
| `Tab:Select()` | Switch to this tab |
| `Tab:SetTitle(text)` | Rename it |
| `Tab:SetIcon(name)` | Swap the sidebar icon |

Sections render as a card. Every element you add becomes a row inside it, separated by hairlines, so grouping is purely a matter of which section you call.

---

## Elements

Every element accepts `Title`, `Description` and `Flag`. Every element returns an object with `:SetTitle()`, `:SetDescription()`, `:Destroy()`, and a `.Value` / `.Instance` field. Anything that holds a value also has `:Set(value, silent)` and `:Get()`.

Passing `silent = true` to `:Set()` updates the control without firing its callback.

### Button

```lua
Section:Button({
    Title = "Open the changelog",
    Description = "Optional second line",
    Callback = function() end,
})
```

### Toggle

```lua
local t = Section:Toggle({ Title = "Fullbright", Default = false, Flag = "fullbright",
                           Callback = function(state) end })
t:Toggle()   -- flip it
```

`Section:Switch` is an alias.

### Slider

```lua
Section:Slider({
    Title = "Field of view",
    Min = 40, Max = 120, Default = 70,
    Increment = 1,        -- step size          (alias: Step)
    Decimals  = 0,        -- decimal places     (alias: Rounding)
    Suffix    = "°",
    Callback  = function(value) end,
})
```

### Input

```lua
Section:Input({
    Title = "Teleport to player",
    Placeholder = "username",
    Default = "",
    Live = false,         -- fire the callback on every keystroke
    Callback = function(text, pressedEnter) end,
})
```

`Section:Textbox` is an alias.

### Dropdown

```lua
local d = Section:Dropdown({
    Title = "Removed effects",
    Options = { "Blur", "Bloom", "Sun rays" },   -- alias: Values
    Multi = true,                                -- alias: MultiSelect
    Default = { "Blur" },
    Placeholder = "None",
    Callback = function(selection) end,
})

d:SetOptions({ "A", "B", "C" })   -- rebuild the list (alias: d:Refresh)
```

Single-select returns the chosen option; multi-select returns an array.

### Keybind

```lua
Section:Keybind({
    Title = "Sprint",
    Default = Enum.KeyCode.LeftShift,
    Callback  = function(key) end,   -- the bound key was pressed in game
    OnChanged = function(key) end,   -- the bind itself changed
})
```

Click the control, then press a key. `Escape` or `Backspace` clears it. Right and middle mouse buttons can be bound too.

### Paragraph, Label, Divider

```lua
Section:Paragraph({ Title = "Heading", Description = "Wrapped body text." })

local l = Section:Label("FPS: --")
l:Set("FPS: 240")

Section:Divider()
```

---

## Notifications and dialogs

```lua
Window:Notify({
    Title = "Config saved",
    Description = "Wrote default.json",
    Icon = "check-circle",
    Duration = 5,
    Callback = function() end,   -- fired if the toast is clicked
})
```

`MacLib:Notify` works identically and does not need a window. Returns `{ Close = function }`.

```lua
Window:Dialog({
    Title = "Unload Aurora?",
    Description = "The interface will be removed.",
    Buttons = {
        { Title = "Cancel" },
        { Title = "Unload", Primary = true, Callback = function() MacLib:Unload() end },
    },
})
```

---

## Settings tab

The controller button in the title bar, left of the theme toggle, opens a settings page. It is
deliberately not a gear — scripts using MacLib usually have their own settings tab with a gear icon,
and two of them side by side is confusing. Press it again and you
land back on whichever tab you were reading. It has no sidebar button — it is a page the window owns
rather than one of your tabs, so it never interferes with your own layout.

**Hide button** — the pill you tap to bring the window back after minimising. It can sit at the
**bottom** (the default), at the **top**, or **anywhere** the user drags it. "Drag to place" makes the
pill appear so it can be dragged live; the position is clamped to the screen edges, so it cannot end
up somewhere unreachable.

**Appearance** — theme, nine accent presets, and the Solar icon weight.

**Window** — interface scale (80–120%), the toggle keybind, background blur, and recentre-on-open.

While the settings page is showing, no sidebar tab is highlighted, since none of them is what you
are looking at.

Every control writes to `MacLib.Prefs`, saved to `MacLib/prefs.json`. These are the *user's*
preferences, not your script's: they persist across sessions and apply to every script that loads
MacLib. Your `Window` config supplies the defaults, and a preference only overrides it once the user
has actually changed that setting.

```lua
MacLib.Prefs.Get("HideButton")        -- "Bottom" | "Top" | "Custom"
MacLib.Prefs.Set("Scale", 1.1)        -- set and save
MacLib.Prefs.Reset()                  -- back to defaults

Window:ToggleSettings()               -- same as pressing the button
Window:OpenSettings()
Window:CloseSettings()
Window:SetScale(1.1)                  -- 0.6 to 1.6
Window:SetBlur(false)
MacLib:SetAccent(MacLib.AccentByName("Purple"))
```

Without file system access the preferences still work for the session; they just cannot persist.

---

## Changelog card

The first time someone runs your script, a card slides into the top-right corner showing what
changed and the MacLib version. It looks like a notification but taller, sits above any toasts, and
stays until dismissed. It appears **once per version** — bump the version and everyone sees it again.

Edit the table near the bottom of `main.lua`:

```lua
MacLib.Changelog = {
    Version = "1.0.1",
    Date    = "12 August 2026",
    Entries = {
        { Tag = "New",      Text = "Colour picker element." },
        { Tag = "Improved", Text = "Dropdowns open upwards when short on space." },
        { Tag = "Fixed",    Text = "Sliders no longer drift on touch devices." },
    },
}
```

Tags are `New` (green), `Improved` (blue), `Fixed` (amber) and `Removed` (red), defined in
`MacLib.ChangelogTags`. Any other tag falls back to the accent colour.

| Call | Description |
| --- | --- |
| `MacLib:ShowChangelog()` | Show it if this version has not been seen |
| `MacLib:ShowChangelog(true)` | Show it regardless — useful for a "changelog" button |
| `MacLib:HasSeenChangelog()` | Has this version been seen on this machine |
| `MacLib:MarkChangelogSeen()` | Mark it seen without showing it |

Pass `Changelog = false` in the window config to suppress the automatic card.

The seen-version marker is written to `MacLib/lastseen.txt`. Without file system access it cannot
persist, so it shows once per session instead — never twice.

---

## Flags and configs

Give any element a `Flag` and it registers into a global table that configs read from.

```lua
MacLib:GetFlag("player.walkspeed")      -- current value
MacLib:SetFlag("player.walkspeed", 100) -- set it, firing the callback
local element = MacLib.Flags["player.walkspeed"]  -- the element object itself
```

```lua
Window:SetFolder("Aurora")          -- default is the window's Folder option
Window:SaveConfig("default")        -- -> Aurora/configs/default.json
Window:LoadConfig("default")
Window:ListConfigs()                -- array of names
Window:DeleteConfig("default")
```

`Enum` values and multi-select tables survive the round trip. All four calls return `false` plus a reason when the executor has no file system functions, so they are safe to call anywhere.

---

## Theming

```lua
MacLib:SetTheme("Light")     -- or "Dark", or a table of your own
```

Colours are tweened live, so the switch animates. The title bar also carries a moon/sun button wired to this.

To restyle, edit `MacLib.Themes.Dark` / `.Light`. Keys: `Window`, `WindowStroke`, `Titlebar`, `Sidebar`, `Divider`, `Card`, `CardStroke`, `Element`, `ElementHover`, `Popup`, `PopupStroke`, `Text`, `SubText`, `Muted`, `Accent`, `AccentText`, `Track`, `Knob`, `Overlay`, `Shadow`.

---

## Icons

Icon names come straight from the [Solar Icon Set](https://solar-icons.vercel.app) — `home-2`, `user-rounded`, `magnifer`, `settings-minimalistic`, and so on.

```lua
Group:Tab({ Title = "Home", Icon = "home-2" })          -- uses the window's IconStyle
Group:Tab({ Title = "Home", Icon = "solar:home-2-bold" })  -- explicit weight
Group:Tab({ Title = "Home", Icon = "rbxassetid://123" })   -- your own asset
```

Weights: `linear`, `outline`, `bold`, `broken`, `bold-duotone`, `line-duotone`.

Use `MacLib.Icons.SetStyle("bold")` to change the weight — it also redraws every icon already on
screen. Assigning `MacLib.Icons.Style` directly only affects icons created afterwards. Icons that
named a weight explicitly (`solar:star-bold`) keep it.

**How it works.** Roblox cannot render SVG, so MacLib ships its own rasteriser. Icons are downloaded through the executor's `request({})` function, parsed (paths with full curve and arc support, plus `circle` / `rect` / `ellipse` / `line` / `polygon`, group inheritance and transforms), scan-converted with anti-aliasing, and written into an `EditableImage`. Roughly 1 ms per icon, cached after the first use.

**When that is not available** — a LocalScript VM with no HTTP, or an executor where `EditableImage` is blocked — MacLib falls back in two stages: an embedded offline set of ~35 hand-drawn Solar-weight icons with a fuzzy alias map, and a vector renderer that draws the geometry with rotated frames. Icons stay visible either way; the [support badge](#support-badge) tells you which route is in use.

Useful fields: `MacLib.Icons.Style`, `MacLib.Icons.DisplayMode()`, `MacLib.Icons.Stats`, `MacLib.Icons.BuiltIn`, `MacLib.Icons.Endpoints`.

---

## Support badge

The bottom of the sidebar shows the detected executor in its own brand colour, followed by a verdict from a self-test that runs on load:

| Badge | Meaning |
| --- | --- |
| `[ Full Support ]` | Every check passed |
| `[ Partial Support ]` | The UI works, but something is degraded — no icons, no HTTP, or no config saving |
| `[ Broken ]` | A critical check failed: the UI cannot be shown or driven |

Eleven checks run: **Interface**, **Layout** and **Input** are critical; **Animation**, **Fonts**, **Vector engine**, **Icon images**, **Solar icons**, **File system**, **Background blur** and **Icon display** are not.

```lua
local support = MacLib:GetSupport()
print(support.Level)    -- "full" | "partial" | "broken"
print(support.Label)    -- "Full Support"
for _, check in ipairs(support.Checks) do
    print(check.Name, check.OK, check.Detail)
end
```

`Icon display` is deliberately observational rather than a capability probe: it watches what the window's own icons actually did, so a failure that none of the probes anticipated still reaches the badge.

Executor colours live in `MacLib.ExecutorColors`, keyed by lowercase alphanumeric name. The list is drawn from the [WEAO](https://weao.gg) tracker plus other executors still in common use; matching tolerates version suffixes, so `Wave 2.4.1` still resolves. Unknown executors show their name in neutral grey.

---

## Environment support

| | |
| --- | --- |
| **Executors** | Full support, including icons and config saving |
| **LocalScript / Studio** | Works, using offline icons; no config saving |
| **Mobile executors** | Works; drag and slider input are touch-aware |

MacLib parents its `ScreenGui` through `gethui()` when available, then `protect_gui` + `CoreGui`, then `CoreGui`, then `PlayerGui`.

---

## Credits

- Icons: [Solar Icon Set](https://solar-icons.vercel.app) by 480 Design
- Executor list: [WEAO](https://weao.gg)

## License

[CC0 1.0 Universal](LICENSE) — public domain dedication. Do anything you like with it, commercially or
otherwise, no attribution required.

Solar artwork is not redistributed here: icons are downloaded at runtime by the end user, and the
embedded offline set is drawn from scratch. The credit above is there because the library is built
around Solar's naming and design language, not because a licence compels it.
