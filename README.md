# InnoViewDualMonitorDriver

**macOS driver for the top screen of InnoView dual stacked portable monitors (InnoView INVPM009, 15.6").**
It makes the second (upper) screen work as a real extended display on Apple Silicon Macs, without the vendor's
"USB Display" driver (MSDisplayManager, `UsbDisplay_macOS_*.pkg`).

The upper screen of these monitors is not a DisplayPort screen: it is a USB display driven by the
**MacroSilicon MS9132** chip (USB ID `345f:9132`, shows up as "USB Video" by "YC"). Without a driver the Mac only
sees the bottom screen, and the vendor's manual says that on a Mac "only splicing and copy modes are supported".
This app is an open-source replacement for that driver: a small menu bar app, no kernel extension, no installer,
no administrator password.

> Not affiliated with or endorsed by InnoView, ShenZhen YingChuang Technology or MacroSilicon.
> Product names are used only to say which hardware this works with.

## Supported hardware

| Device | Status |
|---|---|
| **InnoView INVPM009**, 15.6" dual stacked portable monitor, 1920×1080, top screen on MS9132 (`345f:9132`) | **Tested, works** (see [Tested on](#tested-on)) |
| Other InnoView 15.6" and 18.5" dual-screen monitors whose manual says "Driver installation required for Mac" (the vendor FAQ names **009-05B** and **509-02B**) | Not tested. Should work if the top screen shows up as USB `345f:9132` ([how to check](#is-my-monitor-supported)) |
| Other monitors, docks and adapters with the **MacroSilicon MS9132** chip that use the "USB Display" / MSDisplayManager driver on macOS | Not tested. Might work: the driver finds any `345f:9132` device, but switching the picture on and off is only done for chips wired to HDMI (video port 5), like the INVPM009 |
| InnoView 18" and 23.8" dual-screen monitors (809, 609, 609-01B, 609-02B) and single-screen monitors | **Not needed**: per the vendor, these work on a Mac without any driver (USB-C / DisplayPort) |
| Other MacroSilicon USB display chips (MS912x and others), DisplayLink | **Not supported**: only USB ID `345f:9132` is recognized |

### Is my monitor supported?

Connect the monitor with its USB-C cable and look for the MS9132 in System Information
(Apple menu → About This Mac → More Info → System Report → USB): a device named **USB Video**, manufacturer **YC**,
**Vendor ID 0x345f**, **Product ID 0x9132**. Or in Terminal:

```bash
system_profiler SPUSBHostDataType SPUSBDataType 2>/dev/null | grep -B9 0x9132
```

If it is there, this driver should be able to drive that screen. Please open an issue with the result either way,
so this table can grow.

## Tested on

| | |
|---|---|
| Monitor | InnoView INVPM009, 15.6" dual stacked, 1920×1080@60 Hz per screen. OSD inputs TypeC1 / TypeC2 / HDMI. Its OSD has no "Mac Extend" item under Other Settings |
| Top screen | USB device "USB Video", manufacturer "YC", USB ID `345f:9132`, USB product version 0x3100, chip id `A7 13 0A` (MacroSilicon MS9132), video port 5 (HDMI), EDID vendor `YCT` (0x6474), product 0x95AF |
| Bottom screen | DisplayPort Alt Mode over the same USB-C cable, no driver needed |
| Mac | Mac mini M4 (Mac16,10), Apple Silicon |
| macOS | 27.0.1 |
| Connection | one USB-C cable from the Mac to the monitor, USB 3 link at 5 Gbit/s |
| Date | October 2026 |

Checked on this hardware:
- picture on the top screen at **1920×1080@60** and **1280×720@60**, switching between them from the menu
- partial updates: only the changed parts of the screen are sent
- **upside-down panel**: when the screen is flipped, the monitor reports it and the picture is rotated 180° automatically
- unplugging and plugging the cable back in: the picture returns in about 2.5 s
- Mac sleep and wake, display sleep and wake
- performance with full-screen 25 fps video: every frame delivered, ~104 MB/s over USB, the USB bus is 33–38% busy,
  the app uses ~4% of one CPU core (pixel conversion on the GPU)

Not checked yet:
- a USB 2.0 link (the monitor sometimes comes up as USB 2.0, see [Troubleshooting](#troubleshooting))
- starting automatically at a real login (the login item is registered, but not tried at login)
- other Apple Silicon Macs (M1, M2, M3), Intel Macs, macOS 14–26
- the experimental RGB888 pixel format

## Requirements

- Mac with Apple Silicon, macOS 14 Sonoma or later (tested only on macOS 27)
- Xcode Command Line Tools to build it: `xcode-select --install` (the full Xcode is not needed)
- the monitor connected with a full-function USB-C cable. HDMI does not work: over HDMI the monitor only mirrors

## Install

1. **Quit the vendor driver**, if it is installed: click its menu bar icon → Exit. Only one program can use the USB
   device at a time; while MSDisplayManager runs, this app shows "Device busy" and suggests quitting MSDisplayManager. You can uninstall it as the
   vendor describes: remove it from System Settings → Privacy & Security → Screen & System Audio Recording, then
   move MSDisplayManager from Applications to the Trash.
2. **Build and start** from the repository folder:
   ```bash
   ./InnoViewDualMonitorDriver/build.sh run
   ```
   This builds `InnoViewDualMonitorDriver/build/InnoViewDualMonitorDriver.app`, installs a copy to
   `~/Applications` and starts it. With [just](https://github.com/casey/just) it is `just run`.
3. **Allow screen recording**: the app copies the picture of its virtual display with ScreenCaptureKit, so macOS
   asks for the Screen Recording permission. Until it is given, the top screen stays off and is not added to the
   Mac's displays, so the request and System Settings open on your main screen. Use the menu item
   "No Screen Recording permission — Open Settings…" and turn the switch on. If the top screen does not light up
   within a few seconds, relaunch the app: "Quit & Reopen" if macOS offers it,
   "Permission Granted — Relaunch InnoViewDualMonitorDriver" in the app's menu, or Quit and start it again.
4. The top screen appears in System Settings → Displays as **InnoView USB**. Arrange it above the main screen.
   If you later take the Screen Recording permission away, macOS lets the running app keep it until it quits
   ("Quit & Reopen" or "Later"). After that the app starts without the top screen until the permission is back.

The copy in `~/Applications` adds itself to Login Items once; the "Launch at Login" menu item turns that off, and
removing it in System Settings → General → Login Items also sticks.

The build signs the app ad hoc. The Screen Recording permission then belongs to anything signed ad hoc with the
app's identifier (`com.newparadigma.innoviewdualmonitordriver`), not only to this build. To tie it to your own
certificate (a self-signed "Code Signing" certificate from Keychain Access → Certificate Assistant is enough):
```bash
CODESIGN_IDENTITY="My Code Signing" ./InnoViewDualMonitorDriver/build.sh run
```
After switching between the two, reset the permission as described under
[Troubleshooting](#troubleshooting).

## Using it

The menu bar icon and the first menu line show the state ("Monitor not connected", "Waiting for the monitor", "Running", "Screen asleep", "Device busy" and so on). The menu also has:
- the USB link speed and live frames per second and MB/s
- the resolution of the top screen: 1920 × 1080 or 1280 × 720
- Pixel Conversion: GPU (Metal, the default) or CPU
- Launch at Login, Open Log, Quit. Quitting switches the top screen off and releases the device

## Troubleshooting

- **"Device busy"**: another program holds the device, usually the vendor's MSDisplayManager. Quit it (its menu bar icon → Exit).
- **USB 2.0 warning, low frame rate**: sometimes the monitor gives all four USB-C lanes to DisplayPort and the USB
  part comes up as USB 2.0 (480 Mbit/s). Unplugging and plugging the cable back in helps.
- **The Screen Recording switch is on but the app still has no permission**: the permission was given to a build
  with a different signature. Reset it and allow it again:
  ```bash
  tccutil reset ScreenCapture com.newparadigma.innoviewdualmonitordriver
  ```
- **The top screen stays lit (black) while the Mac's displays sleep**: known. The bottom screen turns off fully, the top
  one keeps its backlight. The vendor driver behaves the same way.
- **The monitor's manual mentions Menu → Other Settings → Mac Extend → On**: the vendor's instructions for Mac
  extended mode say to turn that on. The tested monitor has no such item and works anyway; if yours has it and
  the top screen is not found, try turning it on.
- **Logs**: `~/Library/Logs/InnoViewDualMonitorDriver/driver_*.log` (menu → Open Log; `just log` follows the newest one).
  Please attach the log to bug reports.

Diagnostics without the menu bar app (quit it first, `just stop`):
- `just probe`: chip id, USB speed, connection status and EDID, without changing anything
- `just pattern 10 full`: color bars and a moving square sent straight to the chip for 10 seconds, with fps and MB/s

## How it works

1. The app creates a virtual display (macOS `CGVirtualDisplay`) with the size and EDID identity of the top panel,
   so macOS treats it as a normal extended screen.
2. ScreenCaptureKit captures that display at up to 60 fps together with the list of changed rectangles.
3. The changed parts are converted from BGRA to YUV 4:2:2 (UYVY), the chip's format, on the GPU with Metal
   (or on the CPU with NEON), rotated 180° when the panel is upside down.
4. The rectangles go to the MS9132 as USB bulk transfers through IOKit; control commands go as HID reports.
   No libusb, no kernel extension, no DriverKit.

The protocol was checked against the Linux `ms912x` driver, the vendor's macOS driver and the hardware.

## Keywords

InnoView dual monitor Mac driver · InnoView INVPM009 macOS · InnoView 15.6 inch dual screen portable monitor ·
dual stacked foldable monitor · top screen not working on Mac · extended mode on Mac · Mac Extend ·
USB Display driver macOS · UsbDisplay_macOS · MSDisplayManager alternative · MacroSilicon MS9132 macOS driver ·
USB 345f:9132 · YC USB Video · Apple Silicon M1 M2 M3 M4 · Mac mini · MacBook
