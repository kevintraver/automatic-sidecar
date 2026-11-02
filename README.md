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

This compiles `auto-sidecar` to `~/.local/bin/auto-sidecar` and installs a LaunchAgent (`com.kevintraver.auto-sidecar`) that runs it at login. Plug in your iPad and it becomes a display within a few seconds. Unplug it and, about 4 seconds later, Sidecar ends and the iPad goes to sleep.

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
auto-sidecar watch         # watch for USB iPads (what the LaunchAgent runs)
```

If you have more than one iPad, set `AUTO_SIDECAR_DEVICE` to the device name (as shown by `list`) to choose one. For the LaunchAgent, add it under `EnvironmentVariables` in `~/Library/LaunchAgents/com.kevintraver.auto-sidecar.plist`.

Logs go to `~/Library/Logs/auto-sidecar.log`.

## How it works

### Detecting the cable

IOKit matching and termination notifications fire whenever an Apple (`idVendor` 1452) `IOUSBHostDevice` appears or disappears. If its product string starts with `iPad`, that's the trigger. This is the same mechanism apps like [Stecker](https://apps.apple.com/us/app/stecker/id6447288587) use to run Shortcuts on device attach.

On this macOS version a plain `idVendor` key in the matching dictionary matches nothing; it has to go inside `IOPropertyMatch`.

An iPad drops off USB and comes back while it enumerates, so every change waits 2 seconds for USB to settle before acting on whether an iPad is plugged in.

### After a restart

If the iPad stays plugged in while the Mac restarts, macOS doesn't list it as a USB device until it's replugged, so no plug-in event arrives. So when the agent starts within 5 minutes of boot and no iPad has appeared on USB after 30 seconds, it starts Sidecar anyway. Sidecar still finds the iPad and, in testing, ran the session over the cable (`link type Direct`). Because macOS never registered the iPad on USB, unplugging it after this kind of start isn't detected; replug once or turn Sidecar off from Control Center.

### Starting and stopping Sidecar

It calls the private `SidecarCore.framework`, the API behind Control Center's Screen Mirroring menu:

- `SidecarDisplayManager.sharedManager.devices` lists available iPads
- `connectToDevice:completion:` starts Sidecar
- `disconnectFromDevice:completion:` stops it

A connect can fail while the iPad is still settling, so it retries for up to 20 seconds.

### Unplugging cleanly

Disconnecting right after the cable is pulled leaves the iPad stuck on a "Connection lost" screen, and the next connect fails with an "Unable to Connect" alert on the Mac. The system logs (`log show --predicate 'process == "SidecarRelay" OR process == "rapportd"'`) show why:

1. The Sidecar session runs over the USB cable's direct network link (`link type Direct`), not regular Wi-Fi (the session is flagged `NoiWiFi`).
2. A disconnect sent after the unplug goes out on that dead link and fails (`EADDRNOTAVAIL`), so the iPad never hears it.
3. A few seconds after the unplug, Sidecar's video stream times out (`RTCP Timeout`; the default `rtcpTimeoutInterval` is 3 seconds), and Sidecar reconnects on its own over AWDL, Apple's direct Wi-Fi link between devices.

So on unplug, `auto-sidecar` waits for that wireless reconnect and then disconnects. The disconnect goes out over AWDL, the iPad receives it, and it ends the session and goes to sleep.

To know when the reconnect has happened, it runs `log stream` briefly after the unplug and watches for Sidecar's `Data link type changed Unknown -> AWDL` message, then disconnects half a second later, typically about 4 seconds after the unplug. If that message never shows up (for example, if Apple rewords it), it disconnects 10 seconds after the unplug instead, which was enough in testing (the reconnect took 3–7 seconds).

None of this is documented by Apple. Other tools that use the same API: [Ocasio-J/SidecarLauncher](https://github.com/Ocasio-J/SidecarLauncher) and [sezaakgun/SidecarLauncher](https://github.com/sezaakgun/SidecarLauncher).

## Caveats

`SidecarCore` is a private framework. A future macOS update could rename or change it and break this tool. The unplug handling relies on observed behavior: a log message to know when Sidecar has moved to wireless, and a 10-second fallback when that message doesn't appear. If Sidecar takes longer than that to move to wireless, the iPad may be left on "Connection lost" until it gives up on its own.

## License

[MIT](LICENSE)
