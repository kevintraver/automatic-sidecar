# automatic-sidecar

Start [Sidecar](https://support.apple.com/en-us/102597) automatically when you plug your iPad into your Mac over USB.

macOS has no setting or Shortcuts action for this. `auto-sidecar` is a tiny background agent that listens for an iPad on USB and asks macOS to start Sidecar to it.

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

This compiles `auto-sidecar` to `~/.local/bin/auto-sidecar` and installs a LaunchAgent (`com.kevintraver.auto-sidecar`) that runs it at login. Plug in your iPad and it becomes a display within a second or two.

To remove it:

```sh
./uninstall.sh
```

## Usage

The LaunchAgent runs `auto-sidecar watch`. You can also run it by hand:

```sh
auto-sidecar list       # list Sidecar-capable devices
auto-sidecar connect    # start Sidecar once and exit
auto-sidecar watch      # watch for USB iPads (what the LaunchAgent runs)
```

If you have more than one iPad, set `AUTO_SIDECAR_DEVICE` to the device name (as shown by `list`) to choose one. For the LaunchAgent, add it under `EnvironmentVariables` in `~/Library/LaunchAgents/com.kevintraver.auto-sidecar.plist`.

Logs go to `~/Library/Logs/auto-sidecar.log`.

## How it works

1. **USB detection.** An IOKit matching notification fires whenever an Apple (`idVendor` 1452) `IOUSBHostDevice` appears. If its product string starts with `iPad`, that's the trigger. This is the same mechanism apps like [Stecker](https://apps.apple.com/us/app/stecker/id6447288587) use to run Shortcuts on device attach.
2. **Starting Sidecar.** It calls the private `SidecarCore.framework`, the API behind Control Center's Screen Mirroring menu:
   - `SidecarDisplayManager.sharedManager.devices` lists available iPads
   - `connectToDevice:completion:` starts Sidecar

   The iPad can take a moment to appear in Sidecar's device list after USB enumeration, so it retries for up to 20 seconds. If Sidecar is already connected (for example, it stayed on over Wi-Fi), it does nothing.

Unplugging doesn't disconnect anything. Sidecar either falls back to wireless or ends on its own.

## Caveats

`SidecarCore` is a private framework. A future macOS update could rename or change it and break this tool.

## License

[MIT](LICENSE)
