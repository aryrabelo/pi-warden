/**
 * Module hooks that serve `@earendil-works/pi-tui` without its `MouseRegion` export, standing in for a host whose
 * bundled TUI does not ship that component (omp 18.2.5 is one: it reports
 * `Export named 'MouseRegion' not found in module 'omp-legacy-pi-bundled:@oh-my-pi/pi-tui'`).
 *
 * Every other export is passed through by name, so the only difference from the real module is the one missing
 * component. A named import of it fails at link time; a namespace read yields undefined.
 */
const TARGET = "@earendil-works/pi-tui";
const MARK = "strip-mouse-region";
const REMOVED = "MouseRegion";

export async function resolve(specifier, context, nextResolve) {
  const resolved = await nextResolve(specifier, context);
  if (specifier !== TARGET) return resolved;
  const url = new URL(resolved.url);
  url.searchParams.set(MARK, "1");
  return { ...resolved, url: url.href, shortCircuit: true };
}

export async function load(url, context, nextLoad) {
  const parsed = new URL(url);
  if (!parsed.searchParams.has(MARK)) return nextLoad(url, context);
  parsed.searchParams.delete(MARK);
  const real = parsed.href;
  // Importing the unmarked URL re-enters these hooks and falls through, so the real module loads exactly once.
  const loaded = await import(real);
  const names = Object.keys(loaded).filter(name => name !== REMOVED && name !== "default");
  const lines = [`import * as real from ${JSON.stringify(real)};`];
  for (const name of names) lines.push(`export const ${name} = real[${JSON.stringify(name)}];`);
  if ("default" in loaded) lines.push("export default real.default;");
  return { format: "module", shortCircuit: true, source: lines.join("\n") };
}
