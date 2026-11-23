# ArchiveCam

A native iOS experiment in **camera archaeology**: reproducible compact-CCD and MiniDV-inspired capture, not generic Y2K overlays.

> **Current state: engineering prototype, not a calibrated digital twin.** The profiles are physically motivated starting points. The repository does not yet contain paired reference datasets or empirical calibration against the original cameras. Do not advertise its render as indistinguishable from the originals until blind tests validate it.

## v0.1

- Native SwiftUI interface with understated, instrument-like typography.
- AVFoundation back-camera live preview, microphone capture, autofocus, digital/optical zoom as supported by iPhone, still photographs with physical flash when supported.
- Two profiles: `Compact CCD '04` and `MiniDV PAL '03`.
- GPU Metal simulation: center crop to historical aspect ratio, optical softness, lens-edge falloff, color balance, luminance/chroma noise dependent on scene brightness, channel offset, highlight treatment.
- 50-field/s MiniDV simulation when a 50fps capture format is supported: alternating fields sampled at different instants. Otherwise shows an explicit progressive fallback (does **not** claim genuine 50i).
- Real photo JPEG exports and recorded video with microphone audio to Photos.
- iOS 17+, portrait preview and capture in the first iteration.
- GitHub Actions build and an **unsigned** `.ipa` artifact. It needs signing with your own Apple certificate/service before installation.

## Build locally

```sh
brew install xcodegen
xcodegen generate
open ArchiveCam.xcodeproj
```

Select your Apple Development Team and an available bundle identifier, then run on an iPhone (recommended for camera access). Xcode simulator has no supported physical camera pipeline. The unsigned IPA is not directly installable until signed.

## Data model and calibration policy

Each `CameraProfile` describes image-response and capture choices. It is **not** an empirical model yet. Future validation uses actual matching reference scenes and standardized color patches, ISO sweeps, low-light dark frames, optical edge sharpness, zoom/focus trajectories, interlaced-motion targets and blind A/B comparisons. Each profile should carry calibration provenance, camera firmware, samples and the handset matrix once those exist.

### Fidelity limitations

An iPhone's lens, illuminant, flash, sensor architecture, tone mapping and microphone cannot be perfectly replaced in software. The first implementation receives a processed YUV/BGRA preview feed; it does not magically recover scene-referred RAW video. MiniDV's native DV25 DCT codec is also **not** encoded here: the file is H.264 MP4 with the geometry and some temporal characteristics of DV. Audio is recorded from the real microphone as AAC but is not yet measured/equalized to a particular camcorder. Photograph effects are stronger when validated from a reference camera; the parameter values here are experimental defaults.

### Current output (ArchiveCam 0.7)

ArchiveCam opens in landscape and supports either horizontal grip. The finder and files use 4:3.
The grade keeps neutral subjects neutral and gently boosts middle-strength colours. The right-hand grip holds the shutter, photo/video selector and zoom rocker.
The live finder, JPEG and movie share an 8×8 DCT encode/decode stage with separate luma and colour quantisation. The movie is delivered as H.264 at 1.4 Mb/s for MiniDV, 980 kb/s for Compact 04 and 280 kb/s for Pocket CCD.
Video uses a mono microphone response with profile-specific bandwidth and mild peak compression.
Compact CCD 3MP opens by default and uses a dedicated still exposure. Its 2048×1536 format takes the Nikon COOLPIX 3200 as an example; the colour response is an artistic interpretation. The profile uses gentler quantisation to retain sky gradients.
MiniDV 03 remains selectable. Its JPEG with flash off captures the processed finder frame.
With flash on it uses a separate still exposure. PAL is delivered as a 768×576
square-pixel image in a JPEG or H.264 file.

| Profile | JPEG | H.264 |
| --- | --- | --- |
| Pocket CCD 02 | 1600×1200 | 320×240 |
| Compact CCD 3MP | 2048×1536 | 640×480 |
| Compact 04 | 2592×1944 | 640×480 |
| MiniDV 03 | 768×576 | 768×576 |

## Privacy

Camera + microphone are used locally. Files are stored in the user's Photos library on grant of add-only permission. No backend, account, analytics, networking or model execution is required.

## License

All source is provided for prototype development. Camera/model names are descriptive historical references, not an endorsement or affiliation.
