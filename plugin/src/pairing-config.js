import { readFileSync } from "node:fs";
import { join } from "node:path";

export const DEFAULT_SSH_PORT = 22;

/**
 * Read the plugin-side `pair.json`. A missing or invalid `ssh_port` uses 22,
 * so a Tailscale-SSH Host can advertise OpenSSH on another port without
 * changing the Pairing Code envelope.
 *
 * An override that was written but could not be honored also reports
 * `warning`: falling back to 22 in silence would hand the operator the exact
 * failure the override was meant to avoid. Having no `pair.json` at all is the
 * ordinary case and warns about nothing.
 *
 * @param {string | undefined} configDir `HERDR_PLUGIN_CONFIG_DIR`, or unset
 * @returns {{sshPort: number, warning: string | null}}
 */
export function readPairingConfig(configDir) {
  const fallback = (warning = null) => ({ sshPort: DEFAULT_SSH_PORT, warning });
  if (!configDir) return fallback();

  let contents;
  try {
    contents = readFileSync(join(configDir, "pair.json"), "utf8");
  } catch (error) {
    if (error.code === "ENOENT") return fallback();
    return fallback(`pair.json could not be read (${error.code ?? error.message}).`);
  }

  let parsed;
  try {
    parsed = JSON.parse(contents);
  } catch {
    return fallback("pair.json is not valid JSON.");
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    return fallback("pair.json is not a JSON object.");
  }

  const port = parsed.ssh_port;
  if (port === undefined) return fallback();
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    return fallback(`pair.json ssh_port ${JSON.stringify(port)} is not an integer 1..65535.`);
  }
  return { sshPort: port, warning: null };
}
