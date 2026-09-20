import { readFileSync } from "node:fs";
import { join } from "node:path";

export const DEFAULT_SSH_PORT = 22;

/**
 * Read the plugin-side `pair.json`. A missing or invalid `ssh_port` uses 22,
 * so a Tailscale-SSH Host can advertise OpenSSH on another port without
 * changing the Pairing Code envelope.
 *
 * @param {string | undefined} configDir `HERDR_PLUGIN_CONFIG_DIR`, or unset
 * @returns {{sshPort: number}}
 */
export function readPairingConfig(configDir) {
  let parsed;
  try {
    parsed = JSON.parse(readFileSync(join(configDir, "pair.json"), "utf8"));
  } catch {
    parsed = {};
  }
  const port = parsed.ssh_port;
  const sshPort =
    Number.isInteger(port) && port >= 1 && port <= 65535 ? port : DEFAULT_SSH_PORT;
  return { sshPort };
}
