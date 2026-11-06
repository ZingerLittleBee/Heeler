---
status: accepted; cutting and the test gate superseded by ADR 0039
---

# Tag TestFlight candidates, not App Store publication

A marketing version can contain several TestFlight builds. The old `vX.Y.Z`
workflow recorded only one, while local interim uploads had no build tag.
Use immutable annotated `builds/X.Y.Z/N` tags and one global build counter;
GitHub Actions tests and uploads each candidate. Select the tested build in
App Store Connect without rebuilding or creating a second stable tag.

Git records source identity, not App Store availability. A draft GitHub
prerelease holds the upload checkpoint before the external side effect;
Apple processing success permits its publication as a non-Latest build
record with a matching manifest, reused without replacement on retries.
An uncertain upload blocks automatic re-upload and subsequent uploads.
Local cutting cannot lock out a workflow retry: a newer tag can be reserved
in that race, but the serialized workflow rechecks predecessor settlement
before archive/upload and stops until the uncertainty is reconciled.
This can require manual reconciliation, but avoids treating a lost response
as permission to upload the same identity again. Failed tags/numbers remain.

Keep GitHub Actions rather than adopting Xcode Cloud: the existing signing
and full-test workflow already fits, while Cloud-owned numbering does not
establish preservation of the tag's exact build number through retries.
Retry the original workflow run to retain its source/test identity rather
than testing current `main` and uploading an older candidate.

Publish matching dSYMs as attachments on the same build release. The maintainer
chose public symbols for this open-source app instead of a separate private
repository or object store. Retain and verify the symbols before uploading to
Apple, then expose them when the prerelease is published. Content-addressed
asset names preserve earlier pre-upload attempts; the manifest identifies the
actual uploaded binary's symbols. The whole archive and signing files are not
published. Symbols can include source paths; this policy does not promise
DWARF redaction.

See [the release contract](../guides/releasing.md) for commands, migration,
recovery limits and public symbol retention.
