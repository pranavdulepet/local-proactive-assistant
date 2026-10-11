# Publishing a source release

Source alphas let developers inspect and test a fixed version while device acceptance remains
open. Stable binary distribution has additional gates in [roadmap.md](roadmap.md).
Never label unobserved device behavior as passed.

1. Add versioned notes in `docs/releases/<tag>.md`, update the changelog and README/install
   version, and retain dependency notices. State prerequisites and unresolved acceptance.
2. Run CI on the exact candidate commit. Require successful macOS, phone and source-release jobs.
   Inspect the diff and tracked source for personal records and credentials; the packaging
   checks cover common mistakes, not every possible secret.
3. Merge the reviewed candidate, then wait for CI on the resulting `main` commit. Record that
   commit before creating a tag. Do not move or replace a published tag.
4. Package that exact commit, for example:

   ```bash
   python3 scripts/package-source-release.py v0.2.0-alpha.1 --ref HEAD --output .build/releases/v0.2.0-alpha.1
   cd .build/releases/v0.2.0-alpha.1
   shasum -a 256 -c SHA256SUMS
   ```

   Packaging reads only the selected Git commit, not the working directory. It rejects common
   runtime state, credentials, compiled payloads, symlinks and missing release documents.
   The output includes ZIP, tar.gz, commit metadata and SHA-256 checksums. An existing output
   directory is never overwritten. Extract both archives into temporary directories, confirm
   their file/content parity, and run the documented source build from an extracted archive.
5. Tag the exact passing commit, push the tag, and create a draft GitHub prerelease with the
   versioned notes and all four assets. Verify downloaded assets and the release target, then
   publish the prerelease. Use ordinary release status only when stable acceptance is complete.

The current source-release process excludes build directories, app bundles, third-party binary
downloads, model weights and local source data. A binary release needs dependency notices for
its complete resolved payload, Developer ID signing/notarization, clean-account installation,
permission/update continuity and real-device acceptance.
