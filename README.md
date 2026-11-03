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

### Current output

- Compact video: 480×640 pixels at up to 30p, in portrait, MP4 + AAC.
- MiniDV PAL: 576×768 pixels at up to 25p, portrait square-pixel display equivalent to 4:3 PAL geometry; field synthesis is used only if sampled at 50fps.
- Photos: 1944×2592 for compact and 576×768 for MiniDV-inspired stills, JPEG.

For faithful **landscape** output and archival 720×576 anamorphic DV field layout, a future build should add device-orientation handling and verified pixel aspect-ratio metadata, not blindly stretch the output. 

## Privacy

Camera + microphone are used locally. Files are stored in the user's Photos library on grant of add-only permission. No backend, account, analytics, networking or model execution is required.

## License

All source is provided for prototype development. Camera/model names are descriptive historical references, not an endorsement or affiliation.
