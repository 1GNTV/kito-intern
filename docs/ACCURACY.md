# Reproducibility and accuracy plan

This project deliberately separates **measured camera facts**, **engineering approximations**, and **unverified aesthetic parameters**. Current `CameraProfile` coefficients belong to the last two categories. The target is a measurably faithful model, **not a promise of indistinguishability**.

## Controlled reference kit

For each reference camera and each iPhone model:
1. Identify exact camera model and firmware, focal length, white balance and exposure. Preserve untouched JPEG/AVI/DV files and original metadata; use consistent lighting.
2. Photograph a ColorChecker-style test chart (calibrated illumination, daylight, tungsten) and neutral gray ramps.
3. Photograph a slanted-edge target at center and corners, wide and telephoto, to estimate MTF50 / acutance. Do not infer optical PSF from a generic blur slider.
4. Record flat-field light and covered-lens dark frames at each ISO/exposure; estimate photon shot noise, fixed pattern and chroma noise spatial power spectrum.
5. Record a specular target and overexposed transition to characterize sensor clipping/blooming and ISP tone mapping.
6. For video: test alternating moving bars, zoom sweeps, sudden exposure steps, AF rack tests, sound frequency sweep and compression stress patterns.
7. Shoot the matching scene on each iPhone with the exact capture mode used by the simulation. Align test frames geometrically; do not let photometric alignment hide errors in color, tone or noise.
8. Fit parameters on training scenes, then **evaluate on held-out scenes**. Store fitted profile data, measured error bars and versioned input references.

## Candidate quality gates, subject to baseline verification

These are **proposed thresholds** rather than achieved results.
- Color: report median, p90 and maximum CIEDE2000 on a standard patch set; provisional target median ΔE00 < 6.
- Tone: luminance-curve residual and highlight clipping threshold, independent of reference exposure.
- Spatial: MTF50 relative error < 15% at center and edge in matched framing.
- Noise: ISO-dependent mean-variance curve and noise power spectrum within a defined tolerance, not just grain visual strength.
- Autofocus: convergence latency and overshoot on scene transitions, in frames.
- Video temporal: check field parity, 20ms offset for PAL 50i, motion cadence, audio/video sync drift.
- Perceptual: randomized paired blind test on held-out scenes, report sample sizes and confidence intervals.

## Current limitations

The current Metal stage operates on the **already-processed** camera preview buffers, not linear RAW sensor samples. No iPhone pipeline can resurrect spectral sensitivities, lost highlight headroom, xenon-flash illumination, mechanical zoom or CCD charge-transfer physics. Results are approximations until calibrated and validated. Native DV25, original interlace metadata and historical microphone EQ have not yet been implemented.

A good next stage is an offline calibration harness and separate measured `CalibrationRecord` data for each camera + iPhone hardware combination. When a model's measured evidence is absent, its in-app status should stay **UNVERIFIED**, never **EXACT**.
