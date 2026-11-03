# Calibration and reference procedure

The profiles are experimental starting points, not calibrated replicas of named hardware.
Do not infer model-specific colour or dynamic range from the names or parameters.

## Documented anchors

* Pentax Optio 30 manual: 1/2.7-inch CCD, ISO 50–400 and approx. 15 fps Motion JPEG.
  https://www.ricoh-imaging.co.jp/english/support/man-pdf/optio-30.pdf
* DV PAL is 720×576, 25 frames/s, 50 fields/s and 4:2:0 chroma; DV NTSC is
  720×480, approximately 29.97 frames/s and 4:1:1. Pixel aspect and field order
  must be respected. https://www.loc.gov/preservation/digital/formats/fdd/fdd000183.shtml

## Measurement protocol

Capture matching static and moving scenes on an identified working camera and iPhone,
at the same framing, illuminance, white balance and exposure where possible.
Retain originals, metadata, lens settings and acquisition/transfer method. Use a
grey ramp and colour chart under daylight and tungsten, at several light levels;
include a slanted edge across centre/corners, saturated highlights, fine coloured
lines, moving pendulum and panning detail. Keep displays, codecs and colour
management constant. Measure tone curves and clipping, colour errors, spatial
frequency response, luminance/chroma noise versus signal and illuminance, and
frame/field timestamps and blur; evaluate independent scenes after tuning.
Record coefficients, uncertainty, camera model, sample count and iPhone model.

## Current limitations

No reference media has been measured. All optical, tone, colour and noise coefficients are uncalibrated. ISO-derived
gain controls the synthetic noise and is only an approximation, not sensor noise. iPhone ISP processing cannot be undone.
H.264/AAC is not DV or Motion JPEG; dimensions are square-pixel portrait outputs.
Interlaced source simulation weaves alternating lines into progressive H.264;
it is not a flagged interlaced DV stream and the preview displays the progressive source instants at up to 50/s,
not deinterlaced fields from a DV bitstream. 50 Hz capture depends on the active format;
a 25p fallback is indicated. 15/20/25p are target sampling rates: if unsupported
by the input format, sampling from 30 fps produces uneven frame intervals. If the capture delegate reports a dropped source video frame, or the encoder rejects
video or audio, the recording is discarded and an error is shown. Audio may start
after the first video frame; timing and end duration are not yet verified. Device-side tests of cadence,
audio sync, shutter, orientation, thermal load and image fidelity are still required.
