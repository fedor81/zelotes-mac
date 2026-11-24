# ZelotesMac

## Zelotes C-18 configuration protocol

- USB `12c9:2003`, three HID interfaces. Configuration is on the third (usage page `0xFF00`): 8-byte feature reports carry commands, 64-byte output reports carry tables. macOS delivers output reports to its interrupt OUT endpoint, which the mouse requires. It opens without root or a driver.
- Two profiles. There is no readback: a button write replaces all 11 buttons of a profile, a DPI write its five stages and its lighting, and the old contents cannot be recovered.
- A command is opcode, profile, argument, four zero bytes and a checksum that makes all eight bytes add up to `0xFF`.
- A write is one transaction: begin (`01 88 00`); the DPI part (select profile `02 p`, polling rate `03 p ms`, active stage `04 p n`, prepare `0c p 80`, primer, table); the button part (prepare `0d p 80`, table, 64 zero bytes); commit (`02 p`), which also makes that profile the active one. Either part may be left out. A stage switch on its own is begin, `02 p`, `04 p n`, commit; making a profile active is begin, commit.
- The third byte of a prepare command, `0x80`, is the length of the data phase: 128 bytes in two output reports. Until all of it arrives the mouse sends no movement or button reports and ignores the commit; only a replug recovers it, and nothing is stored.
- Reading the feature report returns the transaction status: byte 0 the last accepted opcode, byte 1 its profile, byte 2 the data bytes still expected.
- The `0x0C` data phase is the primer (`ff ff` and 62 zeros) and then the table; the button data phase is the table and then the zeros.
- `0x0C` table: a fixed header; bytes 7 to 9 the lighting effect, its speed or brightness tier, and a parameter; stage n's sensor code at bytes 19+n (X) and 27+n (Y), always equal; bytes 40 to 63 eight RGB triplets. Profile 2's factory table differs from Profile 1's only in the lighting.
- Sensor codes are not DPI/50. Measured: 200 `04`, 300 `06`, 400 `08`, 600 `0D`, 800 `12`, 1000 `16`, 1200 `1B`, 1600 `24`, 2000 `2E`, 2300 `34`, 2400 `37`, 2600 `3B`, 3000 `45`, 3200 `49`, 4800 `6F`, 5000 `73`; 6600 and 7000 DPI are `CC` and `D0`. Above 5000 DPI bit 7 is set and the low bits are the code of half the DPI.
- Lighting: off `00 00 00`; steady `01 <tier> 03`, tier 1 high, 2 medium, 3 low, every triplet the colour with each lit channel at `31`, `20` or `10`; breathing `02 <speed> 0A` and neon `03 <speed> 00` with fast `04`, medium `08`, slow `0C`; wave `04 <speed> 10` with `03`, `06`, `09`; flowing `06 <speed> 0A` with `3C`, `5F`, `78`. Every effect but steady comes with the palette red, green, blue, yellow, magenta, cyan, white, white at `31`. Factory: Profile 1 wave at medium speed, Profile 2 steady blue at high.
- Polling rate is the interval in ms: 1, 2, 4 or 8. It applies at commit, without a replug. macOS polls the mouse interface every 1 ms whatever the rate.
- Button table: 4 bytes per button, type then value, both 16-bit little-endian. Types: `0000` key (USB keyboard usage; modifiers in the type's high byte, Control, Shift, Option, Command as bits 0 to 3), `0001` mouse click (`F0` left, `F1` right, `F2` middle, `F3` back, `F4` forward), `0003` media (USB Consumer usage), `0007` DPI stage and `0008` profile (1 next, 2 previous, 3 cycle), `F00A` multi-click (its delay a signed byte). Bytes 56 to 63 are always `04 00 01 00 04 00 02 00`.
- Button numbers follow the vendor's diagram: joystick up (7) toward the cable, down (8) toward the palm, left (9) toward the thumb side, right (10) toward the fingers, 11 the press. Thumb button 4 is the one nearer the cable.
- The mouse's own profile and DPI Stage buttons change its state without telling the host.
- The movement report is 7 bytes without a report ID: buttons, X and Y as signed 16-bit little-endian, wheel, horizontal scroll. Reading it needs Input Monitoring. At 1000 Hz, input value callbacks lose most reports; raw reports with timestamps (`IOHIDManagerRegisterInputReportWithTimeStampCallback`) do not.
- Not confirmed on hardware: a stage switch on its own; lighting values other than the two factory ones; whether channel levels other than `10`, `20` and `31` mix colours; whether the animated effects take another palette; whether selecting the profile before `03` and `04` is needed. The factory DPI of stages 1 to 3 (1500, 2500, 4000) is read back from their codes.

## Zelotes T-20

- USB `30fa:1701`, product `USB GAMING MOUSE`, maker `INSTANT`. Two HID interfaces, both on usage page 1: usage 6 is a composite of a keyboard (report 3), Consumer (2), a vendor input report (page `FF00`, ID 6) and the vendor feature report (page `FF01`, ID 7); usage 2 is the plain mouse (report 1).
- No output reports: the longest output report is 1 byte on both interfaces, so the C-18's 64-byte table writes cannot apply here. Configuration is one 8-byte feature report at a time: report ID 7, a command byte, its arguments and zeros, with about 12 ms between packets. Both interfaces take the same reports; `T20Identity` uses usage 2 because usage 6 also carries a keyboard.
- Opening either interface needs Input Monitoring: `IOHIDManagerOpen` answers `0xe00002e2` (`kIOReturnNotPermitted`) without it, and a manager that failed hands out no channel. Only the vendor-page interface of the C-18 opens without the permission.
- macOS ties the Input Monitoring grant to the app's code requirement, so an ad-hoc signature without one loses the grant on every rebuild (`tccd` logs "Failed to match existing code requirement"). `scripts/build-app.sh` therefore signs with `-r='designated => identifier "local.zelotes-mac"'`. `tccutil reset ListenEvent local.zelotes-mac` clears a stale grant.
- Feature report 7 reads back 32 bytes without any write: `07 00 80 08 51 2a 02 1b 11 ss 00 d0 09 00 00 02 20 5a a5 …`. Both interfaces answer it with the same data. On an idle mouse only byte 9 changed, through `00`, `02`, `04`, `06` every five seconds, which is probably an animation. The other bytes are not identified.
- Feature reports 1 to 3 answer with the report ID repeated and zeros, which is not data; only report 7 carries anything.
- No vendor input reports arrive when the buttons are pressed, so the mouse streams nothing about its configuration.
- Its mouse interface (usage 2) sends input report 1, seven bytes: the report ID, the five button bits, X and Y
  as signed 16-bit little-endian values, then the wheel. That is why `ZelotesProbe measure --report-id` fits it.
  It reported at 125 Hz however its stages were set. `ZelotesProbe measure` reads input reports only, so it
  skips the configuration channel the probe otherwise waits for.
- Read it with `ZelotesProbe devices`, then `ZelotesProbe feature --vendor 0x30fa --product 0x1701 --feature-id 7` and `ZelotesProbe listen --vendor 0x30fa --product 0x1701`; all three only read.

### T-20 commands

Every command is one 8-byte feature report, ID 7 first; the chip answers nothing but a status report. The mouse stores nothing, so `T20Writer` sends the whole set after each plug-in and after each change.

- DPI: `07 09 <active stage> <(dpi/200)<<4 | 0x08+stage> <mask of enabled stages>`; four stages, 200 to 3000 in steps of 200, one packet per stage with the same mask.
- Buttons: `07 10 <button> <action>`. Buttons 01 left, 02 wheel, 03 right, 04 side rear, 05 side front, 06 top rear (the DPI button), 08 top front. Actions 00 host (the mouse reports the press to the Mac instead of acting on it), 01 left, 02 middle, 03 right, 04 back, 05 forward, 06 cycle stages, 07 copy, 08 double click, 09 auto-fire, 0B stage up, 0C stage down.
  A binding takes effect at once, without a replug: `ZelotesProbe t20-button --button side-back --action left` was seen to turn that button into a left click in the next HID report. Actions 01, 04, 05, 06, 08, 09, 0B and 0C were each tried on hardware and did what the list says. Action 07 is Copy, not Show Desktop: the mouse sends a keyboard report `03 08 00 07` (report ID 3, Command + C) and nothing else. 0A reports like 00 and does nothing itself.
- A button the mouse works out itself — 01 to 0C — sends nothing else, so the host never learns about it. Actions 00 and 0A instead report the press on the vendor report: page 0x0001 usage 06, report ID 6, `06 <0xF0 + button> 00` on press and `06 <0xF0 + button> 80` on release. That is what a host-side key binding listens to: `T20InputMonitor` opens that interface, `T20InputReport.buttonPress` reads the report, and `ShortcutSender` presses the shortcut with a `CGEvent`. Posting keys needs **Accessibility**, a second permission beside Input Monitoring; the app asks for it the first time a button is given a Mac shortcut. The app offers the six `WindowCommand`s macOS has a default shortcut for, and sends such a button `hostKey` (`T20Settings.action(for:)`).
- Posting a shortcut takes more than the key with its modifier flags. Mission Control's commands (the desktops, Mission Control, App Exposé, Show Desktop) answered to nothing until the app also pressed the modifier keys as key events of their own (0x3B Control, 0x38 Shift, 0x3A Option, 0x37 Command) and set `maskSecondaryFn` on the arrow and function keys, which a real press of them carries; Command-Tab worked without either. Confirmed on hardware: Previous Desktop and Next Desktop now switch spaces.
- The top button also sends `06 f6 00`/`06 f6 80` when a stage change actually happens, and nothing when it is already at the end of the range.
- The mouse tested has six buttons — left, right, wheel, DPI, back, forward — so 08 has no physical button; the app lists `T20Button.onMouse` and calls 06 the DPI button, which a new mouse has cycling the stages.
- Wheel: `07 11 00 00` scroll, `07 11 01 00` volume, `07 11 02 02` reversed. Auto-fire interval: `07 12 00 <0..255>`.
- Lighting: `07 13 7F 17` off, `07 13 7F 10|speed` rainbow breathing (speed 0 to 5). A colour needs all six slots `07 14 <slot<<4 | green><red<<4 | blue>` (slots 0, 2, 4, 6, 8, A, nibble `0xF - channel/16`) and then `07 13 FF <value<<4 | speed> 0B <0xF - brightness> <value & 0xF>`, value 0A steady, 08 breathing, 06 spectrum, speed 0 for steady.
- The mouse has a red and a blue LED only: `00ff00` turns the lighting off, and red and blue are the colours that light.
- The DPI encoding is confirmed by measurement: 400 DPI moved 391 counts per inch, 2000 DPI 1971, both set with
  `ZelotesProbe t20-dpi --dpi <value>`, which gives all four stages one value.
- `ZelotesProbe t20-status`, `t20-dpi`, `t20-light` and `t20-button` send these with tracing; `ZelotesProbe t20-light --usage 2 --light steady --colour ff0000` was seen to light the mouse red, and `t20-button` takes a name or the protocol's own byte for both `--button` and `--action`.

## macOS pointer acceleration

- Acceleration is applied by the HID event system's pointer filter (`IOHIDPointerScrollFilter`, open source in Apple's IOHIDFamily), configured per service through properties. Settings on one service leave other mice and the trackpad alone, and vanish with the service when the device is unplugged. `hidutil dump services` shows each service's accelerator and its curve segments.
- The public simple client (`IOHIDEventSystemClientCreateSimpleClient`) may set the acceleration type but is refused the table and curves. A passive client (`IOHIDEventSystemClientCreateWithType`, type 2, exported by IOKit but not declared) may set them without an entitlement. The user curve key is literally `UserPointerAccelCurvesKey`.
- After the device is unplugged and plugged in again, a client made before that is refused the table; a new client is accepted.
- With Pointer Acceleration off in System Settings the filter scales movement linearly and ignores tables, but only when `HIDPointerAccelerationType` is `HIDMouseAcceleration`. Setting it to `HIDPointerAcceleration`, whose value is never negative, keeps an accelerator. Setting a property in the filter's cached list rebuilds the accelerator; setting the table alone does not.
- `HIDPointerAccelerationAlgorithm` 0 forces the table, 1 the parametric curves, 2 the default order (curves first).
- Table layout, big-endian, 16.16 fixed point unless noted: scale, signature `@200` (4 bytes), curve count (16 bits), then per curve its acceleration index, point count (16 bits) and x, y pairs, joined by straight lines from the origin. The filter picks or blends curves by the acceleration value, so the same curve at the lowest and highest index makes the tracking speed irrelevant. It scales x by resolution / 67 and y by 96 / 67; resolution is `HIDPointerResolution`, 400 counts per inch when unset.
- With `HIDPointerReportRate` set to R, the filter divides each report's movement by the time since the previous report, never by less than 1000/R ms. Without it the curve sees counts per report, so the polling rate changes the acceleration.
- A table set on a service cannot be removed, only replaced. Without one the filter uses a default table compiled into it, found in the installed filter (`/System/Library/HIDPlugins/IOHIDPointerScrollFilter.plugin`) by its signature.
- Windows' Enhance Pointer Precision uses the default `SmoothMouseXCurve` 0.43, 1.25, 3.86, 40 and `SmoothMouseYCurve` 1.37, 5.30, 24.30, 568: mouse speed against pointer speed in inches per second, straight lines from the origin. Windows 7 and later multiply the pointer speeds by 25/32, which leaves the shape of the gain unchanged.

## launchd agents and Background Items

- An agent registered with `SMAppService.agent` can be started by an IOKit matching launch event (`IOProviderClass` `IOUSBHostDevice` with `idVendor` and `idProduct`, `IOMatchLaunchStream`). It must take the event with `xpc_set_event_stream_handler("com.apple.iokit.matching", …)`, or launchd starts it again.
- Registering posts a "Background Items Added" notification that only informs. When the user turns the item off in Login Items, its status becomes `requiresApproval`, and only the user can turn it back on.
- launchd keeps a code requirement for the agent from its registration and refuses other code: `launchctl print gui/$UID/<label>` shows `spawn failed`, `needs LWCR update`, exit 78, and it retries every 10 seconds. Without a Team ID the requirement pins the exact build and launchd cannot repair it; registering again fixes it only after the unregistering has finished, or Background Task Management revives the old item.
- The job runs the program inside the bundle it was registered from; moving the bundle leaves it pointing at nothing.

## App icon tooling

- `actool` compiles an Icon Composer `.icon` into `Assets.car` plus an `AppIcon.icns`, and needs Xcode. It hands the work to a helper process with its own working directory, so its paths must be absolute.
- A fill for the dark icon style goes in `fill-specializations` with `"appearance" : "dark"`; without it the dark icon style uses a near-black fill.
- `NSWorkspace.icon(forFile:)` draws the variant for the icon style in System Settings (`AppleIconAppearanceTheme`), whatever the drawing appearance; the `AppIcon.icns` shows the light one. An app bundle without an executable gets a "prohibited" badge.
