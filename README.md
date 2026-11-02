# automatic-sidecar

Start [Sidecar](https://support.apple.com/en-us/102597) automatically when you plug your iPad into your Mac over USB, and stop it cleanly when you unplug.

macOS has no setting or Shortcuts action for this. `auto-sidecar` is a tiny background agent that listens for an iPad on USB and asks macOS to start or stop Sidecar.

## Requirements

- A Mac and iPad that support Sidecar, signed in to the same Apple Account
- Xcode Command Line Tools (`xcode-select --install`) to compile

Tested on macOS 27.2.

## Install

```sh
git clone https://github.com/kevintraver/automatic-sidecar.git
cd automatic-sidecar
./install.sh
```

This compiles `auto-sidecar` to `~/.local/bin/auto-sidecar` and installs a LaunchAgent (`com.kevintraver.auto-sidecar`) that runs it at login. Plug in your iPad and it becomes a display as soon as it's reachable over the cable, usually within about 6 seconds. Unplug it and, about 3.5 seconds later, Sidecar ends and the iPad goes to sleep. If the iPad is plugged in when you log in, including after a restart, Sidecar starts then.

To remove it:

```sh
./uninstall.sh
```

## Usage

The LaunchAgent runs `auto-sidecar watch`. You can also run it by hand:

```sh
auto-sidecar list          # list Sidecar-capable devices
auto-sidecar connect       # start Sidecar once and exit
auto-sidecar disconnect    # stop Sidecar once and exit
auto-sidecar watch         # watch the USB-C ports (what the LaunchAgent runs)
```

If you have more than one iPad, set `AUTO_SIDECAR_DEVICE` to the device name (as shown by `list`) to choose one. For the LaunchAgent, add it under `EnvironmentVariables` in `~/Library/LaunchAgents/com.kevintraver.auto-sidecar.plist`.

Logs go to `~/Library/Logs/auto-sidecar.log`.

## How it works

Everything is driven by events from macOS; there are no polling loops, and only one timeout, a last-resort fallback on unplug.

### Detecting the cable

The Mac's USB-C port controller reads the identity of whatever is plugged in, over USB Power Delivery. Each port is an `IOAccessoryManager` service in IOKit, and an attached iPad shows up as `SOPMfgString = "iPad"` with `ConnectionActive = Yes`. The agent registers for each port's general-interest notifications, which the kernel sends whenever the port's properties change, so it hears about a plug-in or unplug the moment it happens.

This is more reliable than watching the USB device list (the approach apps like [Stecker](https://apps.apple.com/us/app/stecker/id6447288587) use to run Shortcuts on device attach):

- `ConnectionActive` changes exactly once per plug-in and once per unplug. The iPad's USB device appears, disappears, and reappears while it enumerates.
- After a restart, macOS doesn't list an iPad that stayed plugged in as a USB device until it's replugged, but the port still reports it. So an iPad that's plugged in when the agent starts is handled like any other plug-in.

### Starting Sidecar

It calls the private `SidecarCore.framework`, the API behind Control Center's Screen Mirroring menu:

- `SidecarDisplayManager.sharedManager.devices` lists available iPads
- `connectToDevice:completion:` starts Sidecar
- `disconnectFromDevice:completion:` stops it

Sidecar can only run over the cable once `rapportd` has found the iPad on the cable's network link, a few seconds after plug-in. A connect sent earlier silently goes over wireless instead and takes several seconds longer. So after a plug-in the agent watches the log (`log stream`) for `rapportd`'s `Bonjour device changed ... DirectLink` and connects then. Sidecar's own device status says the same thing (bit `0x1000000`, which SidecarRelay calls `USB`, and a change is announced on the Darwin notification `user.uid.<uid>.com.apple.sidecar-relay.device-generation`). The agent also connects on that signal, but SidecarRelay often publishes the status several seconds late.

### Unplugging cleanly

Disconnecting right after the cable is pulled leaves the iPad stuck on a "Connection lost" screen, and the next connect fails with an "Unable to Connect" alert on the Mac. The system logs (`log show --predicate 'process == "SidecarRelay" OR process == "SidecarDisplayAgent"'`) show why:

1. The Sidecar session runs over the USB cable's direct network link (`link type Direct`), not regular Wi-Fi (the session is flagged `NoiWiFi`).
2. A disconnect sent after the unplug goes out on that dead link and fails (`EADDRNOTAVAIL`), so the iPad never hears it.
3. A few seconds after the unplug, Sidecar's video stream times out (`RTCP Timeout`), and Sidecar reconnects on its own over AWDL, Apple's direct Wi-Fi link between devices.

So on unplug, the agent watches the log until the session is back up over wireless, and only then disconnects. The disconnect goes out over AWDL, the iPad receives it, and it ends the session and goes to sleep. Being back up means `SidecarDisplayAgent` has logged `=== Sidecar Connected ... [AWDL] ===` and then `AVCVideoStream-didStart`, once video is flowing to the iPad again. A disconnect sent between those two lines still leaves "Connection lost" on screen for a few seconds. This typically happens about 3.5 seconds after the unplug.

If the iPad is gone entirely (for example, unplugged while the Mac was asleep), Sidecar's reconnect fails and it logs `Reconnect Failed`; the agent disconnects right away. If neither message shows up within 10 seconds of the unplug (for example, if Apple rewords them), it disconnects anyway.

None of this is documented by Apple. Other tools that use the same API: [Ocasio-J/SidecarLauncher](https://github.com/Ocasio-J/SidecarLauncher) and [sezaakgun/SidecarLauncher](https://github.com/sezaakgun/SidecarLauncher).

## Caveats

`SidecarCore` is a private framework. A future macOS update could rename or change it and break this tool. Several signals are undocumented log messages (`rapportd`'s `DirectLink` discovery, and `SidecarDisplayAgent`'s connect, video-start and reconnect-failure lines) and a status bit, any of which Apple could change. If the plug-in signals change, Sidecar still starts once its own status catches up. If the unplug messages change, the agent falls back to disconnecting 10 seconds after the unplug. If Sidecar takes longer than that to move to wireless, the iPad may be left on "Connection lost" until it gives up on its own.

## License

[MIT](LICENSE)
