import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { before, test } from "node:test";
import { fileURLToPath } from "node:url";
import { MouseRegion, Text } from "@earendil-works/pi-tui";
import { mouseable } from "../src/extension.js";
import { statusWidget } from "../src/widget.js";
import type { ThemeLike } from "../src/widget.js";

const mounter = fileURLToPath(new URL("./fixtures/mount-extension.mjs", import.meta.url));
const root = fileURLToPath(new URL("..", import.meta.url));

/**
 * The mount test below loads the BUILT artifact, because `extensions/index.js` is the entry point Pi actually calls
 * and it re-exports `../dist/extension.js`. That makes the build this file's own precondition rather than the
 * caller's, for two measured reasons: `dist/` is gitignored, so a bare `npm test` on a fresh clone fails with
 * `Cannot find module .../dist/extension.js`; and a STALE `dist` reports the previous source's behaviour, which let
 * the exact regression this file guards pass a full `npm run check` and only fail on the following run.
 */
before(() => {
  const npm = process.env.npm_execpath;
  const [file, args] = npm ? [process.execPath, [npm, "run", "build"]] : ["npm", ["run", "build"]];
  execFileSync(file, args, { cwd: root, encoding: "utf8" });
});

interface Mounted {
  strip: boolean;
  loaded: boolean;
  hasMouseRegion: boolean | null;
  events: string[];
  commands: string[];
  shortcuts: number;
  error: string | null;
}

function mount(...args: string[]): Mounted {
  return JSON.parse(execFileSync(process.execPath, [mounter, ...args], { encoding: "utf8" })) as Mounted;
}

test("the widget renders the same text whether or not the host TUI has a mouse region", () => {
  const theme: ThemeLike = { fg: (_color: string, text: string) => text, bold: (text: string) => text };
  const entries = [
    { guard: "action", line: "warden · action · bash · allow" },
    { guard: "rules", line: "warden · rules · write src/a.ts · 1 violation · violation" },
  ];
  // The body is the production one, the status stack itself, so this measures what a host without the component shows.
  const wrapped = mouseable(statusWidget(entries, theme), () => ({ handled: true }), MouseRegion);
  const plain = mouseable(statusWidget(entries, theme), () => ({ handled: true }), undefined);

  assert.ok(wrapped instanceof MouseRegion, "with the component the widget is wrapped so a click can reach it");
  assert.ok(!(plain instanceof MouseRegion), "without it the status stack stands in rather than nothing at all");
  assert.deepEqual(plain.render(400), wrapped.render(400),
    "the fallback must render the guard lines, not an empty or placeholder widget");
  assert.ok(plain.render(400).join("").includes("1 violation"),
    "and the lines are the real ones");
});

test("a click still opens the trace panel where the host has the component", () => {
  const seen: string[] = [];
  const wrapped = mouseable(new Text("warden", 0, 0), event => {
    if (event.type !== "click") return undefined;
    seen.push(event.type);
    return { handled: true };
  }, MouseRegion);

  const result = (wrapped as MouseRegion).handleMouse({ type: "click", button: "left", x: 0, y: 0 } as never);
  assert.deepEqual(seen, ["click"], "the handler is still wired on a host that supports it");
  assert.ok(result, "and the click is reported handled");
});

test("every guard mounts on a host whose TUI has no mouse region, exactly as on one that has it", () => {
  const withComponent = mount();
  const without = mount("--strip-mouse-region");

  // Guard against a vacuous pass: if the stub silently failed to strip the export, both runs would be the same run.
  assert.equal(withComponent.hasMouseRegion, true, "the real module exports the component");
  assert.equal(without.hasMouseRegion, false, "and the stub host genuinely does not");

  assert.equal(without.error, null, "a missing TUI component must not fail the extension at load");
  assert.equal(without.loaded, true, "the entry point still exports the extension factory");
  assert.deepEqual(without.events, withComponent.events,
    "the same guards are registered: a link error in the widget helper would take all of them down");
  assert.deepEqual(without.commands, withComponent.commands, "and the /warden command survives");
  assert.equal(without.shortcuts, withComponent.shortcuts, "and the shortcut survives");
  assert.ok(without.events.length >= 10, `expected the full guard set, got ${without.events.length}`);
});
