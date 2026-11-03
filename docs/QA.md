# Physical-device QA checklist

- [ ] Camera permission denied: clear message, no crash.
- [ ] Microphone permission denied: video still records silently and shows NO MIC.
- [ ] Metal unsupported / no rear camera: stable error state.
- [ ] Preview displays with correct portrait orientation and live GPU effect.
- [ ] Switch profiles only while not recording; verify output dimensions change.
- [ ] Compact still saves correctly to Photos and has 1944×2592 output.
- [ ] Flash ON and OFF honor physical camera flash availability.
- [ ] Compact video records MP4 at 480×640 with playable audio.
- [ ] MiniDV mode records MP4 at 576×768 at up to 25p.
- [ ] If device supports 50fps, alternating fields represent adjacent capture moments.
- [ ] If 50fps unsupported, no misleading 50i claim in status.
- [ ] Zoom works within active camera bounds, no invalid configuration.
- [ ] Repeated start/stop, app backgrounding, incoming call, permission change, low storage.
- [ ] Audio/video synchronization over 5 minutes and long clip thermal/throughput tests.
- [ ] 100-clip soak test for corrupt files, stalls, retain cycles, photo/video resource spikes.
- [ ] Verify unsigned IPA content includes Payload/ArchiveCam.app (not a signing certificate).
- [ ] Sign via an Apple development/adhoc identity to install; unsigned packaging alone is not sideload-ready.

The first commit has not undergone the above hardware tests or reference-camera calibration.
