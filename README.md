# Amiibo Emulator for iOS

An iPhone app for managing Amiibo on a Chameleon Ultra through Bluetooth.

The app is designed for a straightforward workflow:

1. Connect to a nearby Chameleon.
2. Choose one of its eight slots.
3. Search for an Amiibo.
4. Tap the Amiibo to write it to the selected slot.

Existing slot contents are replaced automatically. The app also includes an
option to clear all eight slots.

## Features

- Connects to a Chameleon Ultra or Chameleon Lite over Bluetooth Low Energy.
- Displays all eight slots and their stored names.
- Marks the slot currently in use.
- Downloads, validates, and caches
  [AmiiboDB](https://github.com/AmiiboDB/Amiibo).
- Searches Amiibo by name or series.
- Writes Amiibo data to empty or occupied slots.
- Reads written data back to verify that the operation succeeded.
- Attempts to restore the previous NTAG slot contents if writing fails.
- Clears all slots using the Chameleon firmware's slot deletion commands.
- Keeps the downloaded Amiibo database available for offline use.

## Hardware Requirements

- An iPhone running iOS 17 or newer.
- A [Chameleon Ultra](https://github.com/RfidResearchGroup/ChameleonUltra) or
  compatible Chameleon Lite.
- Chameleon firmware major version 2.
- Firmware version 2.1.0 or newer is recommended for NTAG215 emulation.
- Bluetooth enabled on the iPhone.
- Internet access for the initial AmiiboDB download and later database updates.

The Chameleon must be powered on and within Bluetooth range while reading,
writing, verifying, or clearing slots.

## Using the App

1. Open the app and tap **Find My Chameleon**.
2. Select the Chameleon shown under **Nearby**.
3. Tap the slot you want to use.
4. Search for and select an Amiibo.
5. Keep the Chameleon nearby and powered on until the operation completes.

Selecting an Amiibo starts writing immediately. If the slot is occupied, its
existing contents are replaced.

To remove everything from the device, open the menu on the slot screen and
select **Clear All Slots**.

## Developer Requirements

- macOS with Xcode.
- Xcode support for the iOS 17 SDK or newer.
- An Apple development team for installation on a physical iPhone.
- A physical iPhone and Chameleon for Bluetooth and write testing.

The project uses SwiftUI, Core Bluetooth, and
[ZIPFoundation](https://github.com/weichsel/ZIPFoundation).

Open the project:

```sh
open "Amiibo Emulator.xcodeproj"
```

Select your development team, choose a connected iPhone, and run the
`Amiibo Emulator` scheme. Bluetooth communication with the Chameleon cannot be
fully tested in the iOS Simulator.

Command-line build verification:

```sh
xcodebuild \
  -project "Amiibo Emulator.xcodeproj" \
  -scheme "Amiibo Emulator" \
  -sdk iphonesimulator \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Project Origins

This app is based on
[amiibo-chameleon-cli](https://github.com/jstolwijk/amiibo-chameleon-cli), a
Rust command-line tool for loading AmiiboDB dumps onto a Chameleon Ultra over
USB.

The CLI served as the behavioral reference for:

- Chameleon protocol framing and command handling.
- AmiiboDB indexing and search.
- NTAG215 dump validation.
- Amiibo authentication page generation.
- Slot inspection and naming.
- Writing and complete read-back verification.
- NTAG backup and best-effort recovery.

Those behaviors were ported to native Swift and adapted for Bluetooth Low
Energy and a non-technical iPhone user interface. The iOS app does not invoke
or embed the Rust CLI.

## Data and Legal Notice

AmiiboDB is an independent external project. This application does not create,
maintain, or guarantee its data.

Only use Amiibo data that you have the legal right to use. Nintendo, Amiibo,
and related names are trademarks of their respective owners. This project is
not affiliated with or endorsed by Nintendo.

Writing or clearing slots changes data stored on the Chameleon. Do not turn off
or disconnect the device while an operation is in progress.
