# Keep staged attachment cleanup outside the mobile client

Heeler may create a staged image or file in the Host's OS-designated temporary storage for a user-requested attachment transfer, but it does not enumerate or delete completed remote attachments. Cleanup belongs to the Host operating system or to a future Herdr-owned capability because remote file maintenance is outside the mobile client's ownership boundary. The current upload operation may delete only its own incomplete `.part` file as failure compensation; it never scans or maintains historical files. We accept that operating-system cleanup has no timing guarantee and that a staged attachment may remain indefinitely.

## Consequences

- The app makes no remote-file TTL or deletion promise.
- Clipboard expiration does not imply deletion of the corresponding remote file.
- A failed or cancelled upload attempts to remove only the incomplete file created by that operation; disconnects may prevent this compensation.
- Staged attachments still use private directories, restrictive permissions, and unguessable names.
- Future deterministic cleanup requires an explicit Herdr-owned interface or a new architectural decision, not a background SFTP sweep from the mobile client.
