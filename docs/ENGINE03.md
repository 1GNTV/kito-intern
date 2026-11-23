# Engine 03: image pipeline rewrite

Three experimental recipes now share an explicit sensor/optics/colour-encoding model:
Pocket CCD 02 (2 MP JPEG, 240x320 15p), Compact 04 (5 MP JPEG, 480x640 15p),
and MiniDV 03 (SD 576x768, 25 frames/s paired from 50 source instants when supported).
Sizes are portrait, square-pixel adaptations.

The shader integrates a source footprint at output resolution before optical softening,
aperture correction, lateral chromatic offsets, colour matrix, linear-domain pedestal,
exposure scale and clipping. Reduced chroma resolution, signal/gain-dependent luminance
and chroma noise and channel quantisation follow. There are no timestamp overlays,
scratches, scan-line masks or light leaks. Coefficients are artist-tuned and unmeasured.
Clipped phone data cannot be recovered; this is a response model after the iPhone ISP.

Pocket video now uses QVGA and a lower bitrate with intra-only H.264. Compact video uses
VGA and a higher intra-only bitrate. These are delivery approximations, not MJPEG or DV.
Stills use the same recipe at photo resolution and profile-specific JPEG quality.
HDR and video stabilisation are disabled where supported; still quality prioritisation
is balanced to reduce multi-frame processing. This does not bypass the iPhone photo ISP.
Focus is single-shot at profile selection; tapping the viewfinder refocuses at centre.
No arbitrary oscillation is added to fake autofocus hunting.

Default profile is now Pocket CCD 02. The masthead says ENGINE 03 and bundle version
0.3.0/300 so a sideloaded older binary can be identified. UI structure is retained.

## Automated checks

CI compiles the production Metal shader for macOS, compiles the actual Swift recipes
with a synthetic GPU harness and, when Metal is exposed, checks differences between
profiles and noise gain, opaque output, and a small timed workload. A missing Metal
device is explicitly reported as a runtime skip, not a pass. iPhone shader compilation,
production cadence checks, IPA ZIP, executable architecture and Metal-library checks
are mandatory. The synthetic workload is not an on-device thermal or performance test.

See CALIBRATION.md for paired real-camera capture and measurement protocol. Device
timing, shutter/motion blur, reference-media fidelity and audio sync still require
real iPhone testing. PAL output remains woven progressive H.264; no native DV export.
