// Copy for pairing popup startup failures. The TUI paints these and waits
// for a key so herdr does not close the pane before the user can read them.

export const MISSING_STATE_DIR =
  "HERDR_PLUGIN_STATE_DIR is not set. Run this popup through herdr.";

export const MISSING_CONFIG_DIR =
  "HERDR_PLUGIN_CONFIG_DIR is not set. Run this popup through herdr.";

export const MISSING_HOST_KEY = [
  "Could not determine this machine's SSH host key.",
  "",
  "If sshd serves keys from a nonstandard location, set the public or",
  "  HEELER_SSH_HOST_KEY=/path/to/ssh_host_ed25519_key",
  "in your shell profile. Otherwise enable Remote Login",
  "(System Settings > General > Sharing), or run:",
  "  sudo ssh-keygen -A",
  "Then invoke pairing again.",
].join("\n");

export const MISSING_ADDRESS =
  "No routable network address found. Connect to a LAN or VPN and retry.";

export function pairingStartFailed(errorMessage) {
  return `Could not start pairing: ${errorMessage}`;
}

export function fatalLines(message) {
  return ["Pairing cannot start", "", message, "", "Press any key to close."];
}
