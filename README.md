# Subvox

A macOS prototype that tests whether AirPods Pro head-motion data (`CMHeadphoneMotionManager`) carries enough information to turn **silently mouthed words into text**.

It doesn't use a language model. It's a small-vocabulary template recognizer plus a statistical test that tells you whether the signal is real.

## Build & run

```sh
brew install xcodegen   # once
xcodegen generate
open Subvox.xcodeproj   # ⌘R
```

Or from the command line:

```sh
xcodebuild -project Subvox.xcodeproj -scheme Subvox -derivedDataPath build -allowProvisioningUpdates build
open build/Build/Products/Debug/Subvox.app
xcodebuild -project Subvox.xcodeproj -scheme Subvox -derivedDataPath build test
```

Requires macOS 14+, AirPods Pro or another headphone that supports head tracking, connected as the Mac's audio output. On first launch, grant **Motion**. The mic and speech prompts only appear when you start the mic.

Run the logic and recording regression tests without launching the app or requesting sensor access:

```sh
swift test
```

The XcodeGen project remains the app build. If you use a different signing team, override `DEVELOPMENT_TEAM` locally when building rather than changing the shared project specification.

## Screens

| Screen | What it does |
|---|---|
| **Sensors** | Live plots of user acceleration, rotation rate and attitude, the measured sample rate, a mic input picker and level meter, and a recorder for experiment sessions. |
| **Train** | Pick a word, hold **Space**, mouth it, release. Each take is stored as a template. **Evaluate** runs leave-one-out classification and a 500× label-permutation test, then shows accuracy against chance, a p-value and a confusion matrix. The feature checkboxes (acceleration / rotation / attitude) let you test which channels carry the signal. |
| **Decode** | The motion-to-text screen. Hold Space, or use auto-detect after calibrating the noise floor. Each segment is DTW-matched against your templates and added to the transcript. A live mic transcript runs alongside it for comparison. |

## How decoding works

1. **Segmentation** (`CaptureController`). Space-hold, or an energy trigger above a calibrated noise floor with pre-roll and hangover.
2. **Features** (`MotionFeatures`). Per frame: user acceleration (3), rotation rate (3), and attitude change since the start of the segment (3). Each channel is mean-centered, and quiet lead-in and lead-out frames are trimmed.
3. **Matching** (`DTW`, `TemplateClassifier`). Each channel is z-scaled across the training set. Matching is 1-nearest-neighbour per word, using dynamic time warping with a Sakoe–Chiba band. A segment is rejected if the best distance is above *max distance* or the margin to the runner-up is below *min confidence*.
4. **Is it real?** (`Evaluation`). The leave-one-out accuracy is compared with the same procedure run on shuffled labels. If p < 0.05, the motion stream distinguishes your words better than chance.

## Experiment protocol

Use **Record Session** in the toolbar or on the Sensors screen. Recordings go to `~/Library/Application Support/Subvox/Sessions/<timestamp>-<condition>-<id>/`. Each session has a unique directory, even when recordings start in the same second:

- `motion.csv`: every motion sample. `t` is seconds from session start.
- `audio.caf`: microphone audio, if the mic is running.
- `events.csv`: every Space-held segment, with its label or prediction.
- `meta.json`: condition, prompt, and the audio start offset for aligning audio with motion.

Suggested runs: the same 5-word script under **Normal speech**, **Whisper** and **Silent mouthing**, 10 reps each. Then, in Train, compare the Evaluate results across feature sets.

The training set lives at `~/Library/Application Support/Subvox/dataset.json`.

## Privacy and recording lifecycle

- Microphone transcription requires on-device speech recognition. If it is unsupported, Subvox reports an error and does not fall back to server recognition; the mic can still be used for local experiment recordings. Required speech assets must be available on the Mac.
- Session and training directories are owner-only (`0700`), and files are owner-readable/writable (`0600`), including atomic dataset replacements. Subvox does not encrypt these files or isolate them from other processes running as your user. System backups can retain copies.
- Recordings remain until you delete them. Use **Show Last Session** to inspect or copy a completed session and **Delete Last Session** to remove it after confirmation. Older sessions can be reviewed and deleted in the Sessions folder. There is no automatic expiry of experiment data.
- Closing the capture window, moving the app to the background, or quitting stops capture and finalizes the recording. Reopening does not automatically restart the microphone. **Stop Recording** finalizes the session; **Stop Mic** controls the separate live microphone/transcript.
- CSV text fields are quoted, embedded control characters are replaced with spaces, and formula-like text is prefixed with a tab inside its quoted cell for spreadsheet analysis. Machine consumers will see that prefix; `meta.json` preserves the original prompt. Treat shared recordings as sensitive data and import CSV text columns as text.

Existing recordings in `~/Documents/Subvox/Sessions/` are not moved or deleted automatically. Review that location separately if you used an earlier version. The training dataset location and JSON format are unchanged; loading it tightens its file permissions.

The app enables Hardened Runtime with the audio-input entitlement. It is still a development prototype without App Sandbox or a notarized distribution configuration. Live permission flows, AirPods/device changes and on-device recognition should be checked on the target Mac before collecting sensitive data.

## Known limits

- Headphone motion is processed and low-rate (roughly 25 Hz on AirPods). The speech-detecting accelerometer and the inward mic are not exposed. Expect jaw and head movement, not vocal vibration.
- Templates are user- and session-specific. Re-seating the AirPods can shift the signal.
- Choosing AirPods as the mic input switches them to the Bluetooth headset (HFP) profile.
