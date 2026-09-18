/**
 * Mounts the built extension against a recording host and reports what it registered, as JSON on stdout.
 *
 * Run with `--strip-mouse-region` to serve a TUI without that component. The point is the whole extension: a link
 * error in one widget helper takes every guard, command, and shortcut down with it, so the counts below are the
 * evidence that the guards survived the host, not just that an import resolved.
 */
import { register } from "node:module";

const strip = process.argv.includes("--strip-mouse-region");
if (strip) register(new URL("./strip-mouse-region-hooks.mjs", import.meta.url));

const report = { strip, loaded: false, hasMouseRegion: null, events: [], commands: [], shortcuts: 0, error: null };
try {
  const tui = await import("@earendil-works/pi-tui");
  report.hasMouseRegion = typeof tui.MouseRegion === "function";

  const entry = await import(new URL("../../extensions/index.js", import.meta.url).href);
  report.loaded = typeof entry.default === "function";

  const pi = {
    on: name => { report.events.push(name); },
    registerCommand: command => { report.commands.push(typeof command === "string" ? command : command?.name); },
    registerShortcut: () => { report.shortcuts += 1; },
    sendMessage: () => undefined,
  };
  entry.default(pi);
} catch (error) {
  report.error = error instanceof Error ? `${error.constructor.name}: ${error.message}` : String(error);
}
process.stdout.write(JSON.stringify(report));
