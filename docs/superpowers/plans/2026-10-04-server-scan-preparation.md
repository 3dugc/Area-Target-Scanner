# Large scan preparation and release

User direction: server provides versioned requirements; iOS prepares a derivative upload to reduce traffic and server work; server retains raw upload compatibility. Preserve original scans and comparison identity.

- [ ] Reproduce 73-frame aggregate-pixel rejection in API and iOS archive.
- [ ] Publish public processing requirements and implement bounded server derivative preparation with actual per-frame calibration.
- [ ] Implement iOS requirements retrieval, immutable derivative archive, cancellation cleanup and raw fallback.
- [ ] Preserve preparation provenance in task/build identities and result manifests.
- [ ] Bound mobile quality feature output and fix UV per-frame intrinsics.
- [ ] Verify unit regressions and generated 100-frame high-resolution fixture.
- [ ] Release only server changes through develop, main and publish CI and image validation.
- [ ] Repull published Portainer images, run large live HTTPS processing/download verification.
- [ ] Run original iOS suite, signed device build and update the connected phone.
