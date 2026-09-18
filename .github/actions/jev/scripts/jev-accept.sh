#!/usr/bin/env bash
# jev-accept.sh — acceptance verdict for a PR, judged by Jev in ONE request.
#
# Subcommands
#   graph   --repo O/R --pr N    the issue graph collected for the PR, as JSON (no Jev request)
#   context --repo O/R --pr N    the assembled context text, exactly as it goes on the wire
#   run     --repo O/R --pr N    context + ONE Jev request + canonical JSON line + summary
#
# Exit codes (contract, identical in both halves)
#   0 verdict obtained, no human needed
#   2 invalid config
#   3 routed to a human
#   4 API/quota/tool failure — fail-open, already warned. NEVER a failed acceptance check.
#
# Everything is context: a source is just a NAME the assembler knows how to fetch.
# There is no privileged source — the issue layers go through the same collector table,
# the same labeller and the same absence handling as the PR's own fields. Adding
# `repo.agents_md` tomorrow is one table entry plus one function, nothing else.
#
# Dependencies: bash 4+, jq, gh, curl, and a python3 that can read the config. Each of
# them is RESOLVED, not assumed: see JEV_TOOL_PATH below and load_config further down.
set -uo pipefail

JEV_ENDPOINT="${JEV_ENDPOINT:-https://openrouter.ai/api/alpha/decisions}"
JEV_TIMEOUT="${JEV_TIMEOUT:-90}"
JEV_CONTEXT_MAX="${JEV_CONTEXT_MAX:-32000}"
JEV_CONFIG_DIR="${JEV_CONFIG_DIR:-.jev}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PY="$SCRIPT_DIR/jev-config.py"
JEV_DEFAULT_MODEL="typesafe/jev-1.13"

# The fleet's self-hosted runners freeze `.path` at `svc.sh install` time, so a job can
# run with the nix profile missing from PATH while the binary sits right there on disk:
# `jq` absent is an EXPECTED condition here, not an exotic one. Same convention as the
# python resolver below — a candidate list, an env escape hatch (JEV_JQ/JEV_GH/JEV_CURL)
# and absence reported as a TOOL problem naming the tool. JEV_TOOL_PATH="" (explicitly
# empty, honoured) confines the search to PATH alone.
JEV_TOOL_PATH="${JEV_TOOL_PATH-/run/current-system/sw/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin}"

# Trim order is part of the contract. issue.body and issue.ancestors are absent from it
# on purpose: they are the plan that gives the rest meaning, so not fitting is a config
# error (exit 2), never a silent trim.
TRUNCATION_ORDER=(pr.diffstat issue.next pr.commits)

declare -A COLLECTORS=(
  [pr.title]=collect_pr_title
  [pr.body]=collect_pr_body
  [pr.commits]=collect_pr_commits
  [pr.diffstat]=collect_pr_diffstat
  [issue.body]=collect_issue_body
  [issue.ancestors]=collect_issue_ancestors
  [issue.next]=collect_issue_next
)
# Sources served by the issue graph. Declared, not sniffed from the name, so the graph
# is fetched once and only when some declared source actually needs it.
declare -A NEEDS_GRAPH=(
  [issue.body]=1
  [issue.ancestors]=1
  [issue.next]=1
)
declare -A BLOCKS=()
declare -a SOURCES=()

# `ausente` is NOT an error and not a pass: it is the measured absence of any declared
# control, and it has to show up in the canonical line, or a run that proves nothing
# about the judge reads exactly like a run that proved something. Everything else is
# reported as `ok`, `fora_da_banda` or `erro`. `status` is the FIRST key of the object
# by contract — the Action reads it with a bash regex, no jq.
CONTROL_ABSENT='{"status":"ausente","cases":[]}'
CONTROL_JSON="$CONTROL_ABSENT"
CONTROL_NAME=""
# One usage object per request actually made (PR + one per control), so `usage` on the
# line is what THIS run cost, not what one of its requests cost.
USAGE_LIST='[]'

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf -- "$WORK"; }
trap cleanup EXIT

warn() { printf 'jev: %s\n' "$*" >&2; }

# A tool problem (missing jq, python without PyYAML, gh refusing) is reported AS a tool
# problem and exits 4, so it can never be mistaken for the PR failing acceptance.
tool_error() {
  TOOL_ERROR="$*"
  warn "erro de ferramenta: $TOOL_ERROR"
}

# Minimal JSON string escaping, for the one line that must be emitted when `jq` itself
# is what went missing. Only what is reachable here: backslash, quote, newline, tab, CR.
json_str() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}

# Resolves one of the hard dependencies. What gets put on PATH is a directory holding a
# single symlink to the resolved binary — NOT the directory it came from. Prepending the
# whole directory would let that binary's neighbours jump the queue in front of the rest
# of PATH, which is how a resolver for `jq` ends up also replacing `curl`.
resolve_tool() {
  local tool="$1"
  local ov_var="JEV_${tool^^}"
  local ov="${!ov_var:-}" dir found="" IFS
  if [ -n "$ov" ]; then
    # An operator who NAMES the binary gets told when that name is wrong, instead of
    # silently falling back to some other one.
    [ -x "$ov" ] || {
      tool_error "$tool nao encontrado ($ov_var=$ov nao e executavel)"
      return 1
    }
    found="$ov"
  elif command -v "$tool" >/dev/null 2>&1; then
    return 0
  else
    IFS=:
    for dir in $JEV_TOOL_PATH; do
      [ -n "$dir" ] && [ -x "$dir/$tool" ] || continue
      found="$dir/$tool"
      break
    done
    IFS=$' \t\n'
    [ -n "$found" ] || {
      tool_error "$tool nao encontrado (nem no PATH nem em JEV_TOOL_PATH=$JEV_TOOL_PATH)"
      return 1
    }
    warn "$tool fora do PATH, usando $found"
  fi
  mkdir -p "$WORK/bin" && ln -sf "$found" "$WORK/bin/$tool" || {
    tool_error "$tool esta em $found mas nao consegui ligar em $WORK/bin"
    return 1
  }
  case ":$PATH:" in *":$WORK/bin:"*) ;; *) PATH="$WORK/bin:$PATH" ;; esac
  return 0
}

summary() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  cat >>"$GITHUB_STEP_SUMMARY"
}

# ---------------------------------------------------------------- config

find_config() {
  local p
  for p in "$JEV_CONFIG_DIR/acceptance.yml" "$JEV_CONFIG_DIR/acceptance.yaml" "$JEV_CONFIG_DIR/acceptance.json"; do
    [ -f "$p" ] && {
      printf '%s' "$p"
      return 0
    }
  done
  return 1
}

# Resolves an interpreter that ACTUALLY reads the config. `python3` names different
# binaries depending on who asks (measured here: /usr/bin/python3 has no PyYAML, the
# nix one does), so candidates are tried until one stops reporting the missing-module
# tool error (exit 5 from jev-config.py). The .json config needs no PyYAML at all.
load_config() {
  local path="$1" out err rc cand
  out="$WORK/config.json"
  err="$WORK/config.err"
  : >"$err"
  local candidates=()
  [ -n "${JEV_PYTHON:-}" ] && candidates+=("$JEV_PYTHON")
  candidates+=(python3 python3.13 python3.12 python3.11 /usr/bin/python3 python)
  for cand in "${candidates[@]}"; do
    command -v "$cand" >/dev/null 2>&1 || continue
    "$cand" "$CONFIG_PY" "$path" >"$out" 2>"$err"
    rc=$?
    if [ "$rc" -eq 5 ]; then
      warn "interpretador $cand nao le YAML, tentando o proximo"
      continue
    fi
    if [ "$rc" -ne 0 ]; then
      cat "$err" >&2
      return "$rc"
    fi
    CONFIG_JSON="$(cat "$out")"
    return 0
  done
  cat "$err" >&2
  tool_error "nenhum python3 disponivel le $path (PyYAML ausente); use $JEV_CONFIG_DIR/acceptance.json"
  return 5
}

# ---------------------------------------------------------------- issue graph

api() { gh api --paginate -H 'Accept: application/vnd.github+json' "$1" 2>>"$WORK/gh.err"; }
api_url() { api "${1#https://api.github.com/}"; }

# Renders a reference the way both halves agreed: bare `#N` inside the PR's own repo,
# `owner/repo#N` when the edge crosses repos (sub-issues and dependencies both can).
disp() {
  local bo="$1" br="$2" owner="$3" repo="$4" n="$5"
  if [ "$owner/$repo" = "$bo/$br" ]; then printf '#%s' "$n"; else printf '%s/%s#%s' "$owner" "$repo" "$n"; fi
}

# jq fragment: same rule as disp(), applied to a REST issue payload.
JQ_DISP='def disp($bo; $br): (.repository_url | split("/")) as $u
  | if ($u[-2] == $bo and $u[-1] == $br) then "#\(.number)" else "\($u[-2])/\($u[-1])#\(.number)" end;'

collect_one_issue() {
  local bo="$1" br="$2" io="$3" ir="$4" n="$5"
  local j
  j="$(api "repos/$io/$ir/issues/$n")" || return 1
  [ -n "$j" ] || return 1

  local ancestors='[]' parent_url depth=0 cur="$j" direct_parent_url=""
  # Walk parent_issue_url to the ROOT — never stop at the direct parent. The root epic's
  # intent is what says whether the delivery makes sense in the plan at all.
  # (Measured: REST exposes parent_issue_url, so this is one GET per level.)
  while :; do
    parent_url="$(jq -r '.parent_issue_url // empty' <<<"$cur")"
    [ -z "$parent_url" ] && break
    [ "$depth" -eq 0 ] && direct_parent_url="$parent_url"
    depth=$((depth + 1))
    if [ "$depth" -gt 20 ]; then
      warn "cadeia de ancestrais passou de 20 niveis, parando"
      break
    fi
    local pj
    pj="$(api_url "$parent_url")" || return 1
    [ -n "$pj" ] || break
    ancestors="$(jq -c --arg bo "$bo" --arg br "$br" --argjson acc "$ancestors" \
      "$JQ_DISP"' $acc + [{n: .number, disp: disp($bo; $br), title: .title, body: (.body // "")}]' <<<"$pj")"
    cur="$pj"
  done

  local root
  if [ "$(jq 'length' <<<"$ancestors")" -gt 0 ]; then
    root="$(jq -c '.[-1]' <<<"$ancestors")"
  else
    root="$(jq -c --arg bo "$bo" --arg br "$br" \
      "$JQ_DISP"' {n: .number, disp: disp($bo; $br), title: .title, body: (.body // "")}' <<<"$j")"
  fi

  # What comes next, one hop: sisters under the direct parent, plus the issues that
  # depend on this one. Both from the native APIs — never from text in a body.
  local next='[]'
  if [ -n "$direct_parent_url" ]; then
    local subs
    subs="$(api_url "${direct_parent_url}/sub_issues")" || return 1
    [ -n "$subs" ] && next="$(jq -c --arg bo "$bo" --arg br "$br" --argjson cur "$n" \
      "$JQ_DISP"' [ .[] | select(.number != $cur)
        | {n: .number, disp: disp($bo; $br), title: .title, state: .state, rel: "irma"} ]' <<<"$subs")"
  fi
  if [ "$(jq '.issue_dependencies_summary.total_blocking // 0' <<<"$j")" -gt 0 ]; then
    local blocking
    blocking="$(api "repos/$io/$ir/issues/$n/dependencies/blocking")" || return 1
    [ -n "$blocking" ] && next="$(jq -c --arg bo "$bo" --arg br "$br" --argjson acc "$next" \
      "$JQ_DISP"' $acc + [ .[]
        | {n: .number, disp: disp($bo; $br), title: .title, state: .state, rel: "bloqueada_por_esta"} ]' <<<"$blocking")"
  fi

  jq -nc --arg bo "$bo" --arg br "$br" --argjson j "$j" \
    --argjson anc "$ancestors" --argjson next "$next" --argjson root "$root" \
    "$JQ_DISP"' ($j | disp($bo; $br)) as $d
      | {n: $j.number, disp: $d,
         repo: ($j.repository_url | split("/") | .[-2:] | join("/")),
         title: $j.title, body: ($j.body // ""), state: $j.state,
         ancestors: $anc, root: $root, next: $next}'
}

# Issues come from closingIssuesReferences — the native link, not a text heuristic over
# the PR body. (Measured: that payload carries number+repository only, title is null,
# so the title/body come from the issue GET, which is the same call that gives the
# parent link and both summaries.)
collect_graph() {
  local repo="$1" pr_json="$2"
  local bo="${repo%%/*}" br="${repo##*/}"
  local closing count i=0 out='[]' entry
  closing="$(jq -c '[.closingIssuesReferences[] | {n: .number, owner: .repository.owner.login, repo: .repository.name}]' "$pr_json")" || return 1
  count="$(jq 'length' <<<"$closing")"
  while [ "$i" -lt "$count" ]; do
    local n io ir
    n="$(jq -r ".[$i].n" <<<"$closing")"
    io="$(jq -r ".[$i].owner" <<<"$closing")"
    ir="$(jq -r ".[$i].repo" <<<"$closing")"
    entry="$(collect_one_issue "$bo" "$br" "$io" "$ir" "$n")" || return 1
    out="$(jq -c --argjson e "$entry" '. + [$e]' <<<"$out")"
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# ---------------------------------------------------------------- collectors

# The bodies are the part of the context their authors fully control, and our labels
# are plain text: a body line that is exactly `## issue.ancestors`, or one shaped like
# `### EPICO RAIZ (#999) ...`, would plant a fake plan under a real label. Only forged
# labels are quoted out with "> " — ordinary markdown (`## O que muda`) passes through
# untouched, so this is byte-identical for every body that is not attacking the format.
JQ_ESCAPE='def esc: split("\n")
  | map(if test("^## (pr|issue|repo)\\.[a-z_]+$")
           or test("^### (ISSUE|CADEIA|EPICO RAIZ|PROXIMAS) \\(")
        then "> " + . else . end)
  | join("\n");'

# Every collector: prints the body of its section, and says out loud when its layer is
# absent. Silence would let Jev judge as if there were no plan — a different question.
collect_pr_title() { jq -r '.title' "$PR_JSON"; }

collect_pr_body() {
  jq -r "$JQ_ESCAPE"' if (.body // "") == "" then "(corpo vazio)" else (.body | esc) end' "$PR_JSON"
}

collect_pr_commits() {
  jq -r 'if (.commits | length) == 0 then "(nenhum commit)"
         else [.commits[] | "\(.oid[0:7]) \(.messageHeadline)"] | join("\n") end' "$PR_JSON"
}

collect_pr_diffstat() {
  jq -r 'if (.files | length) == 0 then "(nenhum arquivo)"
         else [.files[] | "\(.additions)\t\(.deletions)\t\(.path)"] | join("\n") end' "$PR_JSON"
}

collect_issue_body() {
  jq -r "$JQ_ESCAPE"'
         if length == 0 then "sem issue vinculada"
         else [.[] | "### ISSUE (\(.disp)) \(.title)\n\n" +
                     (if (.body | length) == 0 then "(corpo vazio)" else (.body | esc) end)]
              | join("\n\n") end' <<<"$GRAPH_JSON"
}

collect_issue_ancestors() {
  jq -r "$JQ_ESCAPE"'
         if length == 0 then "sem issue vinculada"
         else [.[] | "### CADEIA (\(.disp))\n" +
                     (if (.ancestors | length) == 0 then "issue sem pai — ela é a raiz"
                      else ([.ancestors[] | "\(.disp) \(.title)"] | join("\n")) + "\n" +
                           "### EPICO RAIZ (\(.root.disp)) \(.root.title)\n\n" +
                           (if (.root.body | length) == 0 then "(corpo vazio)" else (.root.body | esc) end)
                      end)]
              | join("\n\n") end' <<<"$GRAPH_JSON"
}

collect_issue_next() {
  jq -r 'if length == 0 then "sem issue vinculada"
         else [.[] | "### PROXIMAS (\(.disp))\n" +
                     (if (.next | length) == 0 then "nenhuma issue seguinte"
                      else ([.next[] | "\(.disp) \(.title) [\(.rel)]"] | join("\n")) end)]
              | join("\n\n") end' <<<"$GRAPH_JSON"
}

collect_blocks() {
  local src fn
  for src in "${SOURCES[@]}"; do
    fn="${COLLECTORS[$src]:-}"
    if [ -z "$fn" ]; then
      warn "config invalida: fonte desconhecida em context: $src"
      return 2
    fi
    BLOCKS["$src"]="$("$fn")" || return 1
  done
  return 0
}

graph_needed() {
  local src
  for src in "${SOURCES[@]}"; do
    [ -n "${NEEDS_GRAPH[$src]:-}" ] && return 0
  done
  return 1
}

# ---------------------------------------------------------------- assembly

# One labeller for every source, so no source can be labelled (or included) by a
# special path. Sections appear in the declared order and nowhere else.
render_context() {
  local out="" src
  for src in "${SOURCES[@]}"; do
    [ -n "$out" ] && out+=$'\n\n'
    out+="## $src"$'\n'"${BLOCKS[$src]}"
  done
  printf '%s\n' "$out"
}

fit_context() {
  CONTEXT="$(render_context)"
  TRUNCATED=false
  [ "${#CONTEXT}" -le "$JEV_CONTEXT_MAX" ] && return 0

  local src cur over target
  for src in "${TRUNCATION_ORDER[@]}"; do
    [ -n "${BLOCKS[$src]+set}" ] || continue
    [ "${#CONTEXT}" -le "$JEV_CONTEXT_MAX" ] && break
    cur="${BLOCKS[$src]}"
    over=$((${#CONTEXT} - JEV_CONTEXT_MAX))
    target=$((${#cur} - over - 12))
    [ "$target" -lt 0 ] && target=0
    BLOCKS["$src"]="${cur:0:$target}"$'\n[TRUNCADO]'
    TRUNCATED=true
    CONTEXT="$(render_context)"
  done

  if [ "${#CONTEXT}" -gt "$JEV_CONTEXT_MAX" ]; then
    warn "config invalida: context nao cabe em $JEV_CONTEXT_MAX sem truncar issue.body/issue.ancestors"
    return 2
  fi
  return 0
}

# ---------------------------------------------------------------- request

# ONE request with ALL the questions. The API's field is still called `state`; only our
# YAML key was renamed to `context`.
ask_jev() {
  local context="$1" model="$2" questions="$3" code curl_rc
  jq -nc --arg model "$model" --arg state "$context" --argjson questions "$questions" \
    '{model: $model, state: $state, questions: $questions}' >"$WORK/request.json" || return 1

  code="$(curl -sS -m "$JEV_TIMEOUT" -o "$WORK/response.json" -w '%{http_code}' \
    -X POST "$JEV_ENDPOINT" \
    -H "Authorization: Bearer $JEV_TOKEN" \
    -H 'Content-Type: application/json' \
    --data-binary "@$WORK/request.json" 2>>"$WORK/curl.err")"
  curl_rc=$?
  HTTP_CODE="$code"

  if [ "$curl_rc" -ne 0 ] || [ -z "$code" ] || [ "$code" = "000" ]; then
    case "$curl_rc" in
      28) FAIL_DETAIL="timeout apos ${JEV_TIMEOUT}s" ;;
      *) FAIL_DETAIL="curl falhou (rc=$curl_rc): $(tr -d '\n' <"$WORK/curl.err" | tail -c 200)" ;;
    esac
    return 1
  fi
  case "$code" in
    200) ;;
    403)
      FAIL_DETAIL="HTTP 403 key limit exceeded"
      return 1
      ;;
    429)
      FAIL_DETAIL="HTTP 429"
      return 1
      ;;
    5??)
      FAIL_DETAIL="HTTP $code"
      return 1
      ;;
    *)
      FAIL_DETAIL="HTTP $code: $(jq -r '.error.message // empty' "$WORK/response.json" 2>/dev/null | tr -d '\n' | cut -c1-200)"
      return 1
      ;;
  esac
  if ! jq -e . "$WORK/response.json" >/dev/null 2>&1; then
    FAIL_DETAIL="resposta nao-JSON"
    return 1
  fi
  if ! jq -e '.answers | objects | length > 0' "$WORK/response.json" >/dev/null 2>&1; then
    FAIL_DETAIL="resposta sem answers"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------- routing

# Polarity lives in routing, not in questions (questions go raw on the wire, an extra
# key there is a 400). expect_low inverts a noul; expect_label pins a choice. noul is a
# PROBABILITY in 0..1, never a boolean — comparing it against a threshold is the whole
# point, and treating it as true/false throws away the verdict.
decide_routing() {
  local answers="$1" cfg="$2" order="$3"
  jq -nc --argjson answers "$answers" --argjson routing "$(jq -c '.routing' <<<"$cfg")" --argjson order "$order" '
    ($routing.human_below) as $hb
    | ($routing.expect_low // []) as $low
    | ($routing.expect_label // {}) as $lab
    | [ $order[] | . as $k | ($answers[$k] // null) as $a
        | if $a == null then empty
          elif $a.type == "noul" then
            if ($low | index($k)) then
              (if $a.noul > (1 - $hb) then "\($k)=\($a.noul) > \(1 - $hb)" else empty end)
            else
              (if $a.noul < $hb then "\($k)=\($a.noul) < \($hb)" else empty end)
            end
          elif $a.type == "choice" and ($lab | has($k)) then
            (if $a.choice != $lab[$k] then "\($k)=\($a.choice) != \($lab[$k])" else empty end)
          else empty end ] as $t
    | {human: ($t | length > 0),
       why: (if ($t | length) > 0 then ($t | join("; ")) else "nenhum limiar cruzado (human_below=\($hb))" end)}'
}

# ---------------------------------------------------------------- calibrated control

# A verdict with no control is unauditable: `atende: 0.88` reads the same whether the
# judge measured this PR or would answer 0.88 to anything at all. A control is a state
# whose answer is already KNOWN, judged by the SAME model, endpoint and timeout, in the
# SAME run, against a band declared in the config.
#
# The band is inclusive ON PURPOSE: `max: 0.89` means "0.89 is still acceptable". The
# `<=`/`>=` below are the whole contract of the edge — turning either into a strict
# comparison silently narrows every band a repo ever declared.
control_band_check() {
  local name="$1" expect="$2" answers="$3"
  jq -nc --arg name "$name" --argjson expect "$expect" --argjson answers "$answers" '
    [ $expect | to_entries[] | .key as $q | .value as $band
      | ($answers[$q] // {}) as $a
      | (if $a.type == "noul" then $a.noul elif $a.type == "score" then $a.score else null end) as $v
      | {name: $name, question: $q, value: $v, band: $band,
         passed: (($v != null)
                  and (($band.min == null) or ($v >= $band.min))
                  and (($band.max == null) or ($v <= $band.max)))} ]'
}

# One request per case — the wire takes one `state` per request, which is why the
# config caps the list at two. Returns 1 only for a TOOL/quota failure, with the case's
# name in CONTROL_NAME so the fail-open message can say which control never answered.
run_control() {
  local model="$1" questions="$2" n i name state expect one cases='[]'
  n="$(jq '.control | length' <<<"$CONFIG_JSON")"
  if [ "$n" -eq 0 ]; then
    CONTROL_JSON="$CONTROL_ABSENT"
    return 0
  fi
  # Declared but not judged yet: from here on the line says `erro`, never `ausente` —
  # claiming absence for a control the repo did ask for is the one lie to avoid.
  CONTROL_JSON='{"status":"erro","cases":[]}'
  for ((i = 0; i < n; i++)); do
    name="$(jq -r ".control[$i].name" <<<"$CONFIG_JSON")"
    state="$(jq -r ".control[$i].state" <<<"$CONFIG_JSON")"
    expect="$(jq -c ".control[$i].expect" <<<"$CONFIG_JSON")"
    CONTROL_NAME="$name"
    if ! ask_jev "$state" "$model" "$questions"; then
      CONTROL_JSON="$(jq -nc --argjson cases "$cases" '{status: "erro", cases: $cases}')"
      return 1
    fi
    USAGE_LIST="$(jq -c --argjson u "$(jq -c '.usage // {}' "$WORK/response.json")" '. + [$u]' <<<"$USAGE_LIST")"
    if ! one="$(control_band_check "$name" "$expect" "$(jq -c '.answers' "$WORK/response.json")")"; then
      FAIL_DETAIL="nao consegui avaliar a banda (jq falhou na resposta do controle)"
      CONTROL_JSON="$(jq -nc --argjson cases "$cases" '{status: "erro", cases: $cases}')"
      return 1
    fi
    cases="$(jq -c --argjson one "$one" '. + $one' <<<"$cases")"
  done
  CONTROL_NAME=""
  CONTROL_JSON="$(jq -nc --argjson cases "$cases" \
    '{status: (if ($cases | any(.passed | not)) then "fora_da_banda" else "ok" end), cases: $cases}')"
  return 0
}

# Cost is charged per REQUEST and a calibrated run makes more than one, so `usage` is
# the sum over the run. With no control declared the list has exactly one element and
# the numbers come out identical to the single response's.
total_usage() {
  jq -nc --argjson list "$USAGE_LIST" '
    reduce $list[] as $u ({};
      reduce ($u | to_entries[]) as $e (.;
        .[$e.key] = (if ($e.value | type) == "number" then ((.[$e.key] // 0) + $e.value) else $e.value end)))'
}

# The absence of a control is reported as loudly as its result: a summary that simply
# omitted the section would let an uncalibrated run pass for a calibrated one. Only the
# two states that reach a rendered summary exist here — `erro` exits through
# fail_open_exit, whose warning already names the control that never answered.
render_control_md() {
  if [ "$(jq -r '.status' <<<"$CONTROL_JSON")" = "ausente" ]; then
    printf 'Nenhum caso declarado (`control:` ausente): esta corrida **não diz** se o juiz está calibrado.\n\n'
    return 0
  fi
  jq -r '.cases[] | "- `\(.name)` / `\(.question)`: **\(.value)** — "
    + (if .passed then ":white_check_mark: dentro" else ":x: FORA" end)
    + " da banda \(.band | to_entries | map("\(.key)=\(.value)") | join(", "))"' <<<"$CONTROL_JSON"
  printf '\n'
}

# ---------------------------------------------------------------- output

emit() {
  jq -nc \
    --argjson pr "$1" --arg repo "$2" --arg model "$3" \
    --argjson answers "$4" --argjson usage "$5" --argjson routing "$6" \
    --argjson truncated "$7" --argjson fail_open "$8" --argjson control "$9" \
    '{pr: $pr, repo: $repo, model: $model, answers: $answers, usage: $usage,
      routing: $routing, truncated: $truncated, fail_open_triggered: $fail_open,
      control: $control}'
}

JQ_ANSWERS_MD='.answers | to_entries[] | .key as $k | .value as $v
  | if $v.type == "noul" then
      "#### `\($k)` — noul **\($v.noul)**\n\n`noul` é a própria probabilidade (0..1) de a afirmação ser verdadeira; este tipo não traz `probabilities` nem `confidence`. Nunca é booleano.\n"
    elif $v.type == "choice" then
      "#### `\($k)` — choice **\($v.choice)** (confidence **\($v.confidence)**)\n\n| rótulo | probabilidade |\n| --- | --- |\n"
      + ([$v.probabilities | to_entries[] | "| `\(.key)` | \(.value) |"] | join("\n")) + "\n"
    else
      "#### `\($k)` — score **\($v.score)** (confidence **\($v.confidence)**)\n\n| nível | critério | probabilidade |\n| --- | --- | --- |\n"
      + ([$v.probabilities | to_entries[] | "| \(.key) | \($v.legend[.key] // "") | \(.value) |"] | join("\n")) + "\n"
    end'

render_summary() {
  local repo="$1" pr="$2" response="$3" routing="$4" truncated="$5"
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  {
    printf '## Jev — verificação de aceite: %s#%s\n\n' "$repo" "$pr"
    printf '**Modelo:** `%s`\n\n' "$(jq -r '.model' <<<"$response")"
    if [ "$(jq -r '.human' <<<"$routing")" = "true" ]; then
      printf '**Veredito:** :warning: pede revisão humana — %s\n\n' "$(jq -r '.why' <<<"$routing")"
    else
      printf '**Veredito:** :white_check_mark: nenhum limiar cruzado — %s\n\n' "$(jq -r '.why' <<<"$routing")"
    fi

    # A verdict is only auditable by whoever reads the PR if the issues that fed the
    # context are named, with numbers and titles.
    printf '### Issues no contexto\n\n'
    if [ "$(jq 'length' <<<"$GRAPH_JSON")" -eq 0 ]; then
      printf 'Nenhuma: o PR não fecha issue (`closingIssuesReferences` vazio). O contexto diz isso explicitamente ao Jev, em vez de omitir.\n\n'
      printf 'Esperado, não é bug: sem issue no contexto o Jev não tem o que comparar e costuma pedir revisão humana. Vincule a issue (`Closes #N`) para ter veredito de aceite.\n\n'
    else
      jq -r '.[] | "- **\(.disp) \(.title)**\n"
        + "  - cadeia até a raiz: " + (if (.ancestors | length) == 0 then "sem pai — ela é a raiz" else ([.ancestors[] | "\(.disp) \(.title)"] | join(" → ")) end) + "\n"
        + "  - épico raiz: \(.root.disp) \(.root.title)\n"
        + "  - próximas (uma hop): " + (if (.next | length) == 0 then "nenhuma" else ([.next[] | "\(.disp) \(.title) _[\(.rel)]_"] | join(", ")) end)' <<<"$GRAPH_JSON"
      printf '\n'
    fi

    printf '### Contexto enviado\n\n'
    printf '%s seções, na ordem declarada: `%s` — %s caracteres.\n\n' \
      "${#SOURCES[@]}" "${SOURCES[*]}" "${#CONTEXT}"
    if [ "$truncated" = "true" ]; then
      printf ':scissors: Passou de %s caracteres e **foi truncado** (ordem: %s). O bloco cortado termina em `[TRUNCADO]`.\n\n' \
        "$JEV_CONTEXT_MAX" "${TRUNCATION_ORDER[*]}"
    fi

    printf '### Controle calibrado\n\n'
    render_control_md

    printf '### Respostas\n\n'
    jq -r "$JQ_ANSWERS_MD" <<<"$response"
    printf '\n### Custo\n\n`%s` (%s requisição(ões) nesta corrida: o PR + uma por controle)\n\n' \
      "$(total_usage)" "$(jq 'length' <<<"$USAGE_LIST")"
    printf '_Veredito probabilístico: serve para rotear e relatar, nunca como único bloqueio de merge._\n'
  } | summary
}

apply_labels() {
  local repo="$1" pr="$2" cfg="$3" routing="$4" response="$5" human label body
  [ "$(jq -r '.routing.labels' <<<"$cfg")" = "true" ] || return 0
  human="$(jq -r '.human' <<<"$routing")"
  if [ "$human" = "true" ]; then label="$(jq -r '.routing.label_human' <<<"$cfg")"; else label="$(jq -r '.routing.label_ok' <<<"$cfg")"; fi

  gh label create "$label" --repo "$repo" --color BFD4F2 --description 'jev: verificacao de aceite' >/dev/null 2>&1
  gh pr edit "$pr" --repo "$repo" --add-label "$label" >/dev/null 2>>"$WORK/gh.err" ||
    warn "nao consegui aplicar a label $label (o job precisa de issues: write)"

  body="$({
    printf 'Jev — verificação de aceite (`%s`)\n\n' "$(jq -r '.model' <<<"$response")"
    if [ "$human" = "true" ]; then
      printf ':warning: **pede revisão humana** — %s\n\n' "$(jq -r '.why' <<<"$routing")"
    else
      printf ':white_check_mark: **nenhum limiar cruzado** — %s\n\n' "$(jq -r '.why' <<<"$routing")"
    fi
    if [ "$(jq 'length' <<<"$GRAPH_JSON")" -eq 0 ]; then
      printf 'Contexto **sem issue vinculada** (`closingIssuesReferences` vazio).\n\n'
    else
      printf 'Issues no contexto: %s\n\n' "$(jq -r '[.[] | "\(.disp) (raiz \(.root.disp))"] | join(", ")' <<<"$GRAPH_JSON")"
    fi
    jq -r '.answers | to_entries[] | .key as $k | .value as $v
      | if $v.type == "noul" then "- `\($k)`: noul **\($v.noul)** (probabilidade, não booleano)"
        elif $v.type == "choice" then "- `\($k)`: **\($v.choice)** (confidence \($v.confidence), probabilities \($v.probabilities | tostring))"
        else "- `\($k)`: score **\($v.score)** (confidence \($v.confidence), probabilities \($v.probabilities | tostring))" end' <<<"$response"
    printf '\n_Probabilístico: roteia e relata, não bloqueia merge sozinho._\n'
  })"
  gh pr comment "$pr" --repo "$repo" --body "$body" >/dev/null 2>>"$WORK/gh.err" ||
    warn "nao consegui comentar no PR (o job precisa de pull-requests: write)"
}

# The ONE exit path that has to survive `jq` itself being the missing tool, so the
# canonical line is built with printf. action.yml reads `human` and
# `fail_open_triggered` out of this line: a jq-built line would come out EMPTY here and
# the Action's outputs would say `false` — a tool failure disguised as "nothing
# happened". Only the two pre-flight failures exit through here; every later tool error
# already has a proven `jq` and keeps the configured model via fail_open_exit.
tool_error_exit() {
  local pr="$1" repo="$2" pr_json="$1"
  local why="sem veredito (fail-open): erro de ferramenta: $TOOL_ERROR"
  # Same numeric assumption as emit()'s --argjson pr, minus the crash.
  case "$pr" in '' | *[!0-9]*) pr_json=null ;; esac
  warn "$why"
  # `erro`, not `ausente`: this exits BEFORE the config is read, so nothing here knows
  # whether a control was declared — only that none was judged.
  printf '{"pr":%s,"repo":%s,"model":"%s","answers":{},"usage":{},"routing":{"human":true,"why":%s},"truncated":false,"fail_open_triggered":true,"control":{"status":"erro","cases":[]}}\n' \
    "$pr_json" "$(json_str "$repo")" "$JEV_DEFAULT_MODEL" "$(json_str "$why")"
  {
    printf '## Jev — verificação de aceite: %s#%s\n\n' "$repo" "$pr"
    printf ':warning: **Sem veredito (fail-open).** erro de ferramenta: %s\n\n' "$TOOL_ERROR"
    printf 'O PR **não** foi reprovado — nenhuma ferramenta pôde julgar o aceite. Instale o que falta (ou aponte `JEV_TOOL_PATH`) e rode de novo.\n'
  } | summary
  return 4
}

# 403/429/timeout/tool error: warn loudly, emit the canonical line with an empty
# verdict, ask for a human, exit 4. NEVER a failed acceptance check.
fail_open_exit() {
  local pr="$1" repo="$2" detail="$3" fail_open="$4" model="$JEV_DEFAULT_MODEL"
  [ -n "${CONFIG_JSON:-}" ] && model="$(jq -r --arg d "$JEV_DEFAULT_MODEL" '.model // $d' <<<"$CONFIG_JSON")"
  local why="sem veredito (fail-open): $detail"
  warn "$why"
  emit "$pr" "$repo" "$model" '{}' "$(total_usage)" \
    "$(jq -nc --arg why "$why" '{human: true, why: $why}')" "${TRUNCATED:-false}" \
    "$(if [ "$fail_open" = "false" ]; then printf 'false'; else printf 'true'; fi)" \
    "$CONTROL_JSON"
  {
    printf '## Jev — verificação de aceite: %s#%s\n\n' "$repo" "$pr"
    printf ':warning: **Sem veredito (fail-open).** %s\n\n' "$detail"
    printf 'O PR **não** foi reprovado — o Jev não respondeu. Peça revisão humana ou rode de novo.\n'
  } | summary
  return 4
}

# A control out of its band says the JUDGE is off, so what that judge said about the PR
# is worth nothing: the verdict is DISCARDED (`answers: {}`), a human is asked, exit 4.
# It never approves and it never reproves — the PR was not judged by anyone reliable.
control_fail_exit() {
  local pr="$1" repo="$2" model="$3" detail why
  detail="$(jq -r '[.cases[] | select(.passed | not)
    | "\(.name)/\(.question)=\(.value) fora de {\(.band | to_entries | map("\(.key)=\(.value)") | join(", "))}"]
    | join("; ")' <<<"$CONTROL_JSON")"
  why="controle fora da banda: $detail"
  warn "$why"
  emit "$pr" "$repo" "$model" '{}' "$(total_usage)" \
    "$(jq -nc --arg why "$why" '{human: true, why: $why}')" "${TRUNCATED:-false}" true \
    "$CONTROL_JSON"
  {
    printf '## Jev — verificação de aceite: %s#%s\n\n' "$repo" "$pr"
    printf ':warning: **Veredito descartado — controle fora da banda.** %s\n\n' "$detail"
    printf 'O PR **não** foi reprovado: o juiz errou um caso de resposta já conhecida, então o que ele disse sobre este PR não vale. Revisão humana.\n\n'
    printf '### Controle calibrado\n\n'
    render_control_md
  } | summary
  return 4
}

# ---------------------------------------------------------------- main

usage() {
  sed -n '2,14p' "$0" >&2
  exit 2
}

main() {
  local cmd="${1:-}"
  shift || true
  local repo="" pr="" bin
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)
        repo="${2:-}"
        shift 2
        ;;
      --pr)
        pr="${2:-}"
        shift 2
        ;;
      --config-dir)
        JEV_CONFIG_DIR="${2:-}"
        shift 2
        ;;
      *)
        warn "argumento desconhecido: $1"
        usage
        ;;
    esac
  done
  case "$cmd" in graph | context | run) ;; *) usage ;; esac
  [ -n "$repo" ] && [ -n "$pr" ] || {
    warn "--repo e --pr sao obrigatorios"
    usage
  }

  WORK="$(mktemp -d "${TMPDIR:-$HOME/.cache}/jev.XXXXXX")"
  : >"$WORK/gh.err"
  : >"$WORK/curl.err"
  TOOL_ERROR=""
  FAIL_DETAIL=""
  TRUNCATED=false
  GRAPH_JSON='[]'
  CONTEXT=""

  local cfg_path
  if ! cfg_path="$(find_config)"; then
    # A repo that does not opt in pays nothing: no request, empty stdout, exit 0.
    warn "sem $JEV_CONFIG_DIR/acceptance.{yml,yaml,json} — no-op"
    printf 'jev: repo não opta (sem `%s/acceptance.yml`) — no-op, nenhuma requisição gasta.\n' "$JEV_CONFIG_DIR" | summary
    return 0
  fi

  if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    tool_error "bash ${BASH_VERSION} e antigo demais (precisa de 4+)"
    tool_error_exit "$pr" "$repo"
    return $?
  fi
  # Pre-flight: a missing tool is a TOOL problem named here, never a cryptic `jq:
  # command not found` forty lines downstream. Deliberately AFTER find_config, so a repo
  # that does not opt in still pays nothing — not even a PATH lookup.
  for bin in jq gh curl; do
    resolve_tool "$bin" || break
  done
  if [ -n "$TOOL_ERROR" ]; then
    tool_error_exit "$pr" "$repo"
    return $?
  fi

  load_config "$cfg_path"
  local rc=$?
  if [ "$rc" -eq 5 ]; then
    fail_open_exit "$pr" "$repo" "erro de ferramenta: $TOOL_ERROR" true
    return $?
  elif [ "$rc" -ne 0 ]; then
    return 2
  fi

  local model questions order fail_open
  model="$(jq -r '.model' <<<"$CONFIG_JSON")"
  questions="$(jq -c '.questions' <<<"$CONFIG_JSON")"
  order="$(jq -c '[.questions | keys_unsorted[]]' <<<"$CONFIG_JSON")"
  fail_open="$(jq -r '.fail_open' <<<"$CONFIG_JSON")"
  mapfile -t SOURCES < <(jq -r '.context[]' <<<"$CONFIG_JSON")

  PR_JSON="$WORK/pr.json"
  if ! gh pr view "$pr" --repo "$repo" \
    --json title,body,commits,files,closingIssuesReferences >"$PR_JSON" 2>>"$WORK/gh.err"; then
    tool_error "gh pr view falhou: $(tr -d '\n' <"$WORK/gh.err" | tail -c 300)"
    fail_open_exit "$pr" "$repo" "erro de ferramenta: $TOOL_ERROR" "$fail_open"
    return $?
  fi

  if [ "$cmd" = "graph" ] || graph_needed; then
    if ! GRAPH_JSON="$(collect_graph "$repo" "$PR_JSON")"; then
      tool_error "coleta do grafo de issues falhou: $(tr -d '\n' <"$WORK/gh.err" | tail -c 300)"
      fail_open_exit "$pr" "$repo" "erro de ferramenta: $TOOL_ERROR" "$fail_open"
      return $?
    fi
  fi
  if [ "$cmd" = "graph" ]; then
    jq . <<<"$GRAPH_JSON"
    return 0
  fi

  collect_blocks || return $?
  fit_context || return 2
  if [ "$cmd" = "context" ]; then
    printf '%s' "$CONTEXT"
    [ "$TRUNCATED" = "true" ] && warn "context truncado (teto $JEV_CONTEXT_MAX)"
    return 0
  fi

  JEV_TOKEN="${JEV_TOKEN:-${OPENROUTER_API_KEY:-}}"
  if [ -z "$JEV_TOKEN" ]; then
    tool_error "OPENROUTER_API_KEY vazio ou ausente"
    fail_open_exit "$pr" "$repo" "erro de ferramenta: $TOOL_ERROR" "$fail_open"
    return $?
  fi

  if ! ask_jev "$CONTEXT" "$model" "$questions"; then
    fail_open_exit "$pr" "$repo" "$FAIL_DETAIL" "$fail_open"
    return $?
  fi

  local response routing
  response="$(cat "$WORK/response.json")"
  USAGE_LIST="$(jq -c '[.usage // {}]' <<<"$response")"

  # The controls are judged AFTER the PR and by the same judge, so a failure here says
  # something about the judge that answered the PR a second ago.
  if ! run_control "$model" "$questions"; then
    fail_open_exit "$pr" "$repo" "controle $CONTROL_NAME: $FAIL_DETAIL" "$fail_open"
    return $?
  fi

  routing="$(decide_routing "$(jq -c '.answers' <<<"$response")" "$CONFIG_JSON" "$order")"

  # Out of band: the verdict computed just above is thrown away, unread. A control can
  # only ever cost a verdict — it can never produce one.
  if [ "$(jq -r '.status' <<<"$CONTROL_JSON")" = "fora_da_banda" ]; then
    control_fail_exit "$pr" "$repo" "$(jq -r '.model' <<<"$response")"
    return $?
  fi

  emit "$pr" "$repo" "$(jq -r '.model' <<<"$response")" \
    "$(jq -c '.answers' <<<"$response")" "$(total_usage)" \
    "$routing" "$TRUNCATED" false "$CONTROL_JSON"

  render_summary "$repo" "$pr" "$response" "$routing" "$TRUNCATED"
  apply_labels "$repo" "$pr" "$CONFIG_JSON" "$routing" "$response"

  [ "$(jq -r '.human' <<<"$routing")" = "true" ] && return 3
  return 0
}

main "$@"
