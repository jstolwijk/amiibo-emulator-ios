# Amiibo Manager for Chameleon Ultra: Implementation Plan

## 1. Goal

Build an iOS SwiftUI application that:

1. Connects to a Chameleon Ultra over Bluetooth Low Energy.
2. Shows the device's eight emulation slots.
3. Downloads AmiiboDB from GitHub as a ZIP archive and stores an extracted local copy.
4. Lets the user select a slot, browse or search AmiiboDB, and choose an Amiibo.
5. Flashes the selected Amiibo into the selected slot.
6. Reads the slot back and verifies that flashing succeeded.
7. Preserves or restores existing NTAG slot data when a flash fails.

The existing Rust CLI in `~/projects/amiibo` is the behavioral reference. Its
database validation, protocol framing, flashing sequence, verification, and
rollback behavior should be ported to Swift rather than invoking or embedding
the CLI.

## 2. Current State

This repository already contains:

- A SwiftUI connection and slot-list screen in `ContentView.swift`.
- BLE discovery and connection using the Chameleon's Nordic UART service.
- Chameleon request framing, response buffering, LRC validation, retries, and
  commands for reading active slot, slot types, and enabled slots.

The existing Bluetooth manager is currently specialized for the three-command
slot refresh workflow. Flashing needs a general command transport that can run
long, serialized operations and return typed responses.

The Rust CLI already provides working reference implementations for:

- AmiiboDB indexing and filtering.
- 540-byte NTAG215 dump validation.
- Chameleon protocol framing.
- Firmware and slot inspection.
- NTAG backup and restore.
- Amiibo authentication page generation.
- NTAG215 programming.
- Complete read-back verification.
- Best-effort rollback after failure.

## 3. Delivery Strategy

Build a proof of concept first. It should prove the complete path from an iOS
device to a verified Amiibo in a selected Chameleon slot without first building
the full product UI or recovery feature set.

### Proof of Concept

- iOS only.
- Manual scan, connect, and disconnect.
- Display all eight slots, the active slot, and slot nicknames.
- Download AmiiboDB from the `main` branch ZIP.
- Check for a database update on launch at most once in a rolling 24-hour
  period.
- Retain the downloaded database for offline use.
- Search a simple text list of validated Amiibo.
- Select a slot, select an Amiibo, confirm, flash, and verify it.
- Allow overwrite of any occupied HF slot after an explicit warning.
- Back up and roll back NTAG-family slots where the protocol supports complete
  recovery.
- Clearly warn that overwriting a non-NTAG slot has no automatic rollback.
- Show coarse operation stages and page-write progress.

The proof of concept is complete only when a physical iPhone can flash a known
Amiibo to a physical Chameleon Ultra over BLE and the app verifies the result.

### Product Build-Out

- iPhone and iPad app.
- Rich series browsing and filtering.
- Polished database management and update states.
- Persistent recovery management and restore UI.
- User-visible backup export/import.
- Multiple saved database versions.
- More detailed slot inspection and management.
- Editing nicknames independently.
- Reordering or copying slots.
- Accessibility and complete interruption handling.

### Explicitly Deferred

- Amiibo artwork or external image APIs.
- macOS and visionOS support.
- Background database downloads.

## 4. Proposed Architecture

Split the current large Bluetooth manager into small components with explicit
responsibilities.

### Models

- `ChameleonDevice`: discovered BLE peripheral summary.
- `ChameleonSlot`: slot number, HF/LF type, enabled state, nickname, and active
  state where available.
- `AmiiboEntry`: stable ID, series, display name, relative dump path, and UID.
- `ValidatedAmiiboDump`: validated 540-byte data and extracted seven-byte UID.
- `FlashProgress`: preparation, backup, writing, configuration, verification,
  rollback, and completion states.
- `NtagBackup`: complete state needed for best-effort restoration.

### Services

- `ChameleonBLETransport`
  - Owns `CBCentralManager`, `CBPeripheral`, and UART characteristics.
  - Sends one request at a time.
  - Splits outgoing frames according to
    `maximumWriteValueLength(for: .withResponse)`.
  - Reassembles fragmented notifications.
  - Applies request timeouts and rejects unexpected responses.

- `ChameleonProtocol`
  - Encodes and decodes `0x11 0xEF` frames.
  - Validates header and payload LRC values.
  - Defines command IDs, status codes, payload length checks, and protocol
    errors.
  - Has no SwiftUI or CoreBluetooth dependencies, allowing unit tests.

- `ChameleonClient`
  - Provides async typed operations such as `inspectSlots()`,
    `setActiveSlot()`, `readPages()`, and `writePages()`.
  - Reads the HF nickname for each slot using command `1008`.
  - Implements firmware checks, backup, restore, flash, and verification.
  - Ports the command order and safety checks from `src/device.rs`.

- `AmiiboDatabaseService`
  - Downloads a GitHub ZIP archive with `URLSession`.
  - Extracts into a staging directory.
  - Validates the expected `Amiibo Bin` directory before replacing the current
    cache.
  - Indexes only valid selectable dumps.
  - Publishes download/index state and last successful update date.

- `AmiiboDumpValidator`
  - Ports the checks from `src/dump.rs`.
  - Remains independent from files and UI where possible by validating `Data`.

- `AmiiboManagerViewModel`
  - Coordinates connection, slot selection, database state, Amiibo selection,
    confirmation, flashing, progress, cancellation policy, and errors.
  - Prevents slot refresh or disconnect actions from starting during a flash.

### UI

- `DeviceView`: connection state and discovered devices.
- `SlotListView`: eight slot cards/rows and active-slot marker.
- `AmiiboPickerView`: searchable list grouped or filterable by series.
- `AmiiboRow`: name and series initially; artwork can be added later.
- `FlashProgressView`: non-dismissable progress while device state is being
  changed.
- `DatabaseSettingsView`: download/update/delete cache and show cache status.

## 5. AmiiboDB ZIP Workflow

Use the GitHub repository archive endpoint rather than Git because iOS cannot
run the CLI's Git workflow.

Proposed flow:

1. Download the repository ZIP using an ephemeral `URLSession` download task.
2. Show determinate progress when the server reports a content length.
3. Save the download to a temporary staging location.
4. Extract the ZIP with a maintained Swift ZIP package, proposed:
   `ZIPFoundation`.
5. Locate the extracted repository root without depending on the generated
   top-level archive directory name.
6. Require an `Amiibo Bin` child directory.
7. Recursively scan `Amiibo Bin`.
8. Skip hidden entries and `!Essential Files`.
9. Accept only `.bin` files that are exactly 540 bytes and pass dump
   validation.
10. Build display identities as `series / filename`.
11. Write a small generated JSON index containing relative paths and metadata.
12. Atomically replace the previous cache only after extraction and indexing
    both succeed.
13. Retain the previous usable database if download, extraction, or indexing
    fails.

Store the extracted database and generated index under Application Support.
Exclude the cache from iCloud backup because it is downloadable content.

On launch, check whether an update check has succeeded within the previous 24
hours. If not, perform one lightweight update check. Download and replace the
ZIP only when the remote revision differs from the stored revision. A failure
must not prevent offline use or repeatedly retry during the same launch.

Also provide a manual `Check for Updates` action. Store the last successful
check time and remote revision in cache metadata.

The archive source for the proof of concept is the AmiiboDB `main` branch.

## 6. Slot Name Detection

Displaying an Amiibo name is possible, with two confidence levels.

### Primary Method: Slot Nickname

The Chameleon protocol exposes the HF nickname for every slot through command
`1008`. The existing Rust CLI sets this nickname to the Amiibo name during a
flash. Therefore:

- Slots flashed by this app or the existing CLI can display their nickname
  immediately.
- Reading the nickname does not require changing the active slot.
- A nickname is user-controlled metadata, so label it as the slot name rather
  than cryptographic proof of the exact Amiibo dump.

This is included in the proof of concept.

### Fallback Method: UID Matching

For an NTAG-family slot with no useful nickname, the app can:

1. Remember the active slot.
2. Temporarily activate the candidate slot.
3. Read its ISO14443-A UID.
4. Match that UID against UIDs in the local validated AmiiboDB index.
5. Restore the originally active slot.

This can identify a database dump even when no nickname was stored. It is more
invasive because it temporarily changes the active slot and may find no match
for custom or modified dumps. Implement it after the proof of concept behind an
explicit `Identify Slots` action rather than running it automatically on every
refresh.

When both are available, show:

- A database-matched name as `Identified`.
- A nickname-only name as `Slot nickname`.
- `Unknown NTAG` when neither method produces a match.

## 7. Dump Validation

Port the CLI's validation before any device write:

- File is inside the extracted `Amiibo Bin` tree.
- File size is exactly 540 bytes.
- UID is bytes `0, 1, 2, 4, 5, 6, 7`.
- BCC0 and BCC1 check bytes are valid.
- NTAG215 dynamic lock page 130 is `01 00 0F BD`.
- Configuration pages 131 and 132 match the expected values.
- PWD/PACK pages contain the unreadable zero placeholders expected in raw
  dumps.
- `!Essential Files`, keys, hidden files, and malformed dumps are never
  presented as selectable Amiibo.

Re-read and revalidate the selected file immediately before flashing.

## 8. BLE Protocol Refactor

Replace the current `pendingSlotCommands/currentCommand` implementation with a
general async request queue:

1. Only one Chameleon command may be in flight.
2. Match each response to the expected command.
3. Validate status and exact/ranged payload length per command.
4. Preserve the existing receive buffer because BLE notifications may split or
   combine frames.
5. Chunk outgoing frame bytes to the peripheral's supported BLE write length.
6. Apply a timeout per command.
7. Retry only read-only/idempotent operations automatically.
8. Do not blindly retry page writes or other destructive commands; read state
   or fail into rollback instead.
9. Cancel pending continuations when the device disconnects.
10. Keep all BLE delegate interaction on the main actor while exposing
    `async throws` operations to the client.

Add firmware commands `1000` and `1017` so the app can require firmware major
version 2 and warn for versions older than 2.1.

## 9. Flashing Workflow

Port the working CLI sequence without changing command semantics:

1. Revalidate the selected Amiibo dump.
2. Confirm that the device is connected and firmware is compatible.
3. Refresh complete slot metadata.
4. If the slot is occupied, show its type and nickname and require explicit
   overwrite confirmation.
5. If the target contains an NTAG-family tag, capture a complete in-memory
   backup and verify that it is restorable.
6. If the target is non-NTAG, warn that its current contents cannot be restored
   automatically.
7. Configure the selected slot as tag type `1101` (`NTAG_215`).
8. Initialize the slot data.
9. Make the selected slot active.
10. Derive the four-byte Amiibo password from the UID.
11. Replace pages 133 and 134 with the derived password and PACK
    `80 80 00 00`.
12. Write all 135 pages in protocol-sized batches.
13. Configure anti-collision data:
    - UID: extracted seven-byte UID.
    - ATQA: `44 00`.
    - SAK: `00`.
    - ATS: empty.
14. Disable UID-magic mode.
15. Set write mode to normal.
16. Set a UTF-8 nickname truncated safely to 32 bytes.
17. Enable HF emulation.
18. Save slot configuration.
19. Read back and compare all 540 bytes.
20. Verify page count, UID, ATQA, SAK, ATS, UID-magic mode, write mode, slot
    type, HF enablement, and nickname.
21. Leave the successfully flashed slot active.
22. Refresh the displayed slots and show success.

Progress should be based on completed protocol steps and page batches, not a
timer.

## 10. Failure and Recovery

- Validate the database and dump before connecting or modifying a slot.
- Disable navigation and competing device commands during destructive work.
- Treat a BLE disconnect during flashing as an unknown device state.
- For an existing NTAG-family slot, attempt to restore the captured backup
  after any write or verification failure.
- Verify the restored state after rollback.
- If rollback fails, clearly report both the original and rollback errors.
- Keep the backup in Application Support when rollback cannot be verified so a
  later recovery feature can use it.
- If the original slot was empty and flashing fails, disable HF for that slot
  and restore the previously active slot where possible.
- If a non-NTAG slot is overwritten, recovery of its previous contents is not
  available. This limitation must be present in the confirmation dialog.
- Do not describe flashing or rollback as transactional.

The proof of concept should not allow cancellation after the first destructive
command. The user may cancel during download, indexing, or preflight only.

## 11. User Flow

1. Launch the app.
2. If no database exists, show `Download Amiibo Database`.
3. Scan for and connect to a Chameleon Ultra.
4. Display slots.
5. Tap a slot to select it.
6. Present the Amiibo picker for that slot.
7. Search or browse by series and tap an Amiibo.
8. Show a confirmation containing the target slot, current slot contents, and
   selected Amiibo.
9. Start the flash.
10. Show stage and page-write progress.
11. On success, return to slots with the target selected and active.
12. On failure, show whether rollback succeeded or whether recovery is needed.

An occupied slot always requires explicit confirmation. A non-NTAG HF slot can
be overwritten only after the user accepts that automatic rollback is
unavailable.

## 12. Proof-of-Concept Steps and Progress

Status values:

- `Not started`
- `In progress`
- `Implemented`
- `Hardware verified`
- `Blocked`

Overall progress: **proof of concept hardware verified**.

| Step | Goal | Status | Progress | Completion evidence |
| --- | --- | --- | ---: | --- |
| P0 | Approve this proof-of-concept plan and remaining assumptions. | Implemented | 100% | The proof of concept targets iPhone on iOS 17 or newer. |
| P1 | Establish an iOS-only, testable project baseline. | In progress | 85% | A generic iPhone iOS 17 build succeeds with the resolved package graph; a test target is still required. |
| P2 | Replace the slot-specific BLE state machine with a reusable serialized command transport. | Hardware verified | 90% | Serialized async requests, BLE chunking, timeout/retry handling, and disconnect cancellation work on physical hardware; automated tests remain. |
| P3 | Read firmware, slots, and HF nicknames through the new client. | Hardware verified | 100% | Firmware, all eight slots, and HF nicknames were read successfully on physical hardware. |
| P4 | Download, extract, validate, cache, and search the AmiiboDB `main` ZIP. | In progress | 95% | Download, ZIPFoundation extraction, validated indexing, atomic replacement, searchable UI, and offline loading are implemented; automated verification remains. |
| P5 | Add the 24-hour launch update check and manual update action. | In progress | 85% | Revision metadata, rolling 24-hour launch gating, and manual update UI are implemented; automated verification remains. |
| P6 | Port dump validation and Amiibo authentication-page generation. | In progress | 80% | Validation and authentication-page generation match the Rust implementation; an automated test target remains. |
| P7 | Implement slot selection, Amiibo selection, overwrite confirmation, and progress UI. | Hardware verified | 95% | The complete selection, confirmation, flash, and progress flow works on physical hardware; automated UI coverage remains. |
| P8 | Implement NTAG215 flash commands and full read-back verification. | Hardware verified | 95% | A known Amiibo was flashed and verified by the app on physical hardware; fake-device tests remain. |
| P9 | Add NTAG backup and best-effort rollback around flashing. | In progress | 85% | Complete NTAG state capture, verified rollback, empty-slot cleanup, and failed-rollback recovery persistence are implemented; injected-failure hardware and automated tests remain. |
| P10 | Prove the complete workflow on an iPhone and Chameleon Ultra. | Hardware verified | 100% | User confirmed the complete physical iPhone-to-Chameleon flash and verification workflow works. |

Progress rules:

- Update a step to `Implemented` only when its code and automated tests pass.
- Update a hardware-dependent step to `Hardware verified` only after recording
  the device, firmware, slot, and observed result.
- Update the percentage when work lands, rather than only at milestone end.
- Record blockers in the table and in a short log below it.
- Do not start product build-out until P10 is hardware verified.

### Minimum Deployment Target

The proof of concept targets **iOS 17.0** on iPhone.

## 13. After the Proof of Concept

Do not expand scope until P10 is hardware verified. Then prioritize:

1. Add the explicit UID-based `Identify Slots` action.
2. Add persistent recovery browsing, restore, import, and export.
3. Improve series browsing, filters, database settings, and empty/error states.
4. Add accessibility, Dynamic Type, and broader iPhone/iPad layouts.
5. Harden backgrounding, Bluetooth interruption, reset, and reconnect behavior.
6. Add slot copy, reorder, rename, and other management features.
7. Revisit artwork only after the device-management workflow is stable.

## 14. Test Plan

### Unit Tests

- Frame encoding and LRC values.
- Fragmented and concatenated response parsing.
- Command/status/payload validation.
- Name normalization and duplicate display names.
- ZIP root discovery and invalid archive handling.
- Database exclusions and generated index.
- Dump size, UID, BCC, lock, configuration, and PWD/PACK validation.
- Password and PACK generation.
- Page batch construction.
- Nickname truncation at UTF-8 boundaries.
- Flash state-machine success and each failure stage using a fake client.
- Backup serialization and validation.

### Integration Tests

- Download from a local fixture HTTP server or bundled ZIP fixture.
- Replace an existing cache only after a valid update.
- Simulated BLE transport for timeouts, disconnects, bad checksums, wrong
  responses, partial verification, successful rollback, and failed rollback.

### Hardware Tests

- Scan, connect, disconnect, and reconnect.
- Read all eight slots repeatedly.
- Flash an empty slot and verify with both the app and existing CLI.
- Flash over an existing NTAG slot.
- Overwrite a non-NTAG occupied slot only after the no-rollback warning.
- Disconnect during preflight, writing, and verification.
- Confirm rollback with an intentionally injected post-backup failure.
- Verify operation with the minimum supported iOS version and current
  Chameleon firmware.

## 15. Proof-of-Concept Acceptance Criteria

- A fresh install can download and index AmiiboDB without Git.
- The app can browse the downloaded database without network access.
- Invalid and support `.bin` files never appear in the picker.
- Launch performs no more than one database update check per rolling 24 hours.
- The user must select a slot before choosing an Amiibo.
- Slots flashed by this app or the CLI display their stored nickname.
- The app never has more than one protocol command in flight.
- A selected valid dump is written as all 135 NTAG215 pages.
- A flash is not reported successful until complete read-back verification
  passes.
- Existing restorable NTAG state is backed up before overwrite.
- A failed flash either verifies rollback or reports that recovery is
  incomplete.
- Slot state refreshes after a successful flash or rollback.
- The UI remains explicit about connected device, selected slot, selected
  Amiibo, current operation, and final result.
- The complete workflow is verified on physical hardware.

## 16. Decisions

| Decision | Outcome | Status |
| --- | --- | --- |
| Platform | iOS only. | Approved |
| ZIP extraction | Use ZIPFoundation. | Approved |
| AmiiboDB source | Use the `main` branch ZIP. | Approved |
| Update policy | Check on launch at most once per 24 hours and retain manual update. | Approved |
| Artwork | Do not include artwork now. | Approved |
| Non-NTAG overwrite | Permit after an explicit no-rollback warning. | Approved |
| Recovery UI | Keep recovery internal during the proof of concept. | Proposed |
| Minimum iOS version | Use iOS 17.0. | Awaiting approval |
| UID-based slot identification | Add after the proof of concept as an explicit action. | Proposed |
