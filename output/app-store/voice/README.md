# Voice Input App Store screenshot

`compose_voice.py` renders "Just Say It." as the second image of all three
screenshot slots:

| Slot | Export | Size |
| --- | --- | --- |
| iPhone 6.9-inch | `../iphone-6.9/exports/01b-just-say-it.png` | 1320 × 2868 |
| iPad 13-inch | `../ipad-13/exports/01b-just-say-it.png` | 2752 × 2064 |
| iPhone Duo | `../iphone-duo/exports/01b-just-say-it.png` | 2853 × 2007 |

Instead of a whole device, each image shows only the Composer. The recording bar
is enlarged with the Agent's last reply fading in above it, and below it the
transcribed draft waits with the caret at its end. Each slot keeps its own
background and title style.

## Sources

`sources/` holds two unedited captures per device, taken on 2026-11-22 in the
Docs Agent's Chat. Captures come from the iPhone 17 Pro Max and iPad Pro 13-inch
(M5) simulators on iOS 27.0 and the iPhone Duo (unfolded) simulator on iOS 27.1.
The app was built from `a91b5045`, the commit of 0.1.21 (57), and connected to
the `scripts/store-shots.py` rig, so the conversation is a real Codex session.

- `*-recording.png` is taken five seconds into a recording.
- `*-draft.png` is taken after the transcript landed in the Composer.

The transcript is real: an OpenAI transcription of the spoken prompt, through
the maintainer's own key. The waveform is not live microphone input, because
the simulator records near silence. A temporary recorder replayed a speech
clip synthesized with macOS `say`, so the levels follow real speech. That
recorder only existed in a local build and is not in the repository.

## Regenerate

From the repository root, with Pillow and NumPy installed:

```sh
python3 output/app-store/voice/compose_voice.py
```

The renderer crops and scales the captures uniformly, then masks them. It does
not redraw any application content. Each piece is the Composer's card above its
Agent strip, so the Agent's status line is part of it. The reply above the bar
has the Chat background subtracted and is screened onto the field, so only its
text shows and no band marks where the piece ends.
