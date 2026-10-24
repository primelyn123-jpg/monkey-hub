# Monkey Hub

Script hub for **Survive a Million Monkeys** with a premium UI (hypercar intro, loading screen, draggable window).

## Run

Start a match, then execute:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/primelyn123-jpg/monkey-hub/main/MonkeyHub.lua"))()
```

- **RightCtrl** opens and closes the menu.
- Settings are saved to `MonkeyHub/settings/config.json` in your executor workspace.
- Optional: put an `intro.mp3` in your executor workspace folder to play music during the intro (it plays silently without one).
- The hub only runs inside a match, not the lobby.

## Files

- `MonkeyHub.lua` - the hub.
- `ui.lua` - the UI library (downloaded automatically).

Game API details can change with game updates.
