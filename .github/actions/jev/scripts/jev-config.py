#!/usr/bin/env python3
"""Load and validate .jev/acceptance.{yml,yaml,json} into normalised JSON on stdout.

Exit codes: 0 valid; 2 invalid config; 5 tool error (interpreter cannot read YAML).
5 is internal: jev-accept.sh maps it to the contract's exit 4 (fail-open) so a
missing PyYAML never reads as a failed acceptance check.
"""
import json
import re
import sys

KNOWN_SOURCES = (
    "pr.title",
    "pr.body",
    "pr.commits",
    "pr.diffstat",
    "issue.body",
    "issue.ancestors",
    "issue.next",
)
QUESTION_TYPES = ("noul", "choice", "score")
DEFAULT_MODEL = "typesafe/jev-1.13"
TOP_KEYS = ("version", "model", "context", "questions", "routing", "fail_open", "control")
ROUTING_KEYS = (
    "human_below",
    "labels",
    "expect_low",
    "expect_label",
    "label_human",
    "label_ok",
)
# Calibrated control: cases whose answer is already KNOWN, judged in the SAME run as
# the PR. The cap is a COST decision, not a taste one: the wire takes one `state` per
# request, so each declared case is one extra request on every run.
CONTROL_KEYS = ("name", "state", "expect")
BAND_KEYS = ("min", "max")
CONTROL_MAX = 2
CONTROL_NAME_RE = re.compile(r"^[a-z0-9_]+$")


def die(msg, code=2):
    sys.stderr.write("jev: config invalida: %s\n" % msg)
    sys.exit(code)


def load(path):
    with open(path, "r", encoding="utf-8") as fh:
        raw = fh.read()
    if path.endswith(".json"):
        try:
            return json.loads(raw)
        except ValueError as exc:
            die("%s nao e JSON valido: %s" % (path, exc))
    try:
        import yaml  # noqa: PLC0415 - lazy: the .json path must not need PyYAML
    except ImportError:
        sys.stderr.write(
            "jev: erro de ferramenta: o interpretador %s nao importa PyYAML.\n"
            "jev: instale PyYAML ou use .jev/acceptance.json (nao precisa de PyYAML).\n"
            % sys.executable
        )
        sys.exit(5)
    try:
        return yaml.safe_load(raw)
    except Exception as exc:  # yaml.YAMLError and friends
        die("%s nao e YAML valido: %s" % (path, exc))


def validate(cfg, path):
    if not isinstance(cfg, dict):
        die("%s: raiz precisa ser um mapa" % path)
    # A silently ignored config key is a known way to lose a day, so an unknown one is
    # an error. `state:` names the API's wire field, not our YAML key: it is rejected by
    # name so the rename cannot half-apply.
    unknown = [k for k in cfg if k not in TOP_KEYS]
    if unknown:
        hint = " (use `context:`)" if "state" in unknown else ""
        die("chave(s) desconhecida(s) na raiz: %s%s" % (", ".join(sorted(unknown)), hint))
    if cfg.get("version") != 1:
        die("version precisa ser 1 (veio %r)" % cfg.get("version"))

    model = cfg.get("model", DEFAULT_MODEL)
    if not isinstance(model, str) or not model:
        die("model precisa ser string nao vazia")

    context = cfg.get("context")
    if not isinstance(context, list) or not context:
        die("context precisa ser uma lista nao vazia de fontes")
    for src in context:
        if src not in KNOWN_SOURCES:
            die("context: fonte desconhecida %r (conhecidas: %s)" % (src, ", ".join(KNOWN_SOURCES)))
    if len(set(context)) != len(context):
        die("context: fonte repetida")

    questions = cfg.get("questions")
    if not isinstance(questions, dict) or not questions:
        die("questions precisa ser um mapa nao vazio")
    for key, q in questions.items():
        if not isinstance(q, dict):
            die("questions.%s precisa ser um mapa" % key)
        qtype = q.get("type")
        if qtype not in QUESTION_TYPES:
            die("questions.%s.type precisa ser um de %s (veio %r)" % (key, ", ".join(QUESTION_TYPES), qtype))
        if not isinstance(q.get("instructions"), str) or not q["instructions"].strip():
            die("questions.%s.instructions precisa ser string nao vazia" % key)
        if qtype == "choice":
            crit = q.get("criteria")
            if not isinstance(crit, dict) or len(crit) < 2:
                die(
                    "questions.%s: choice exige instructions (string) e criteria (map com 2+ rotulos)"
                    % key
                )
            for label, rubric in crit.items():
                if not isinstance(rubric, str) or not rubric.strip():
                    die("questions.%s.criteria.%s precisa ser uma rubrica em texto" % (key, label))
        elif qtype == "score":
            crit = q.get("criteria")
            if not isinstance(crit, list) or len(crit) < 2:
                die(
                    "questions.%s: score exige instructions (string) e criteria (lista do menor ao maior, 2+ itens)"
                    % key
                )
            for item in crit:
                if not isinstance(item, str) or not item.strip():
                    die("questions.%s.criteria: todos os itens precisam ser texto" % key)
        elif "criteria" in q:
            die("questions.%s: noul nao aceita criteria" % key)

    routing = cfg.get("routing") or {}
    if not isinstance(routing, dict):
        die("routing precisa ser um mapa")
    unknown = [k for k in routing if k not in ROUTING_KEYS]
    if unknown:
        die("routing: chave(s) desconhecida(s): %s" % ", ".join(sorted(unknown)))
    human_below = routing.get("human_below", 0.7)
    if not isinstance(human_below, (int, float)) or isinstance(human_below, bool) or not 0 < human_below < 1:
        die("routing.human_below precisa ser numero entre 0 e 1 (veio %r)" % human_below)
    labels = routing.get("labels", True)
    if not isinstance(labels, bool):
        die("routing.labels precisa ser booleano")
    expect_low = routing.get("expect_low", [])
    if not isinstance(expect_low, list):
        die("routing.expect_low precisa ser lista de nomes de pergunta")
    expect_label = routing.get("expect_label", {})
    if not isinstance(expect_label, dict):
        die("routing.expect_label precisa ser mapa pergunta -> rotulo esperado")
    for name in expect_low:
        if name not in questions:
            die("routing.expect_low: %r nao e uma pergunta declarada" % name)
        if questions[name]["type"] != "noul":
            die("routing.expect_low: %r nao e do tipo noul" % name)
    for name, want in expect_label.items():
        if name not in questions:
            die("routing.expect_label: %r nao e uma pergunta declarada" % name)
        if questions[name]["type"] != "choice":
            die("routing.expect_label: %r nao e do tipo choice" % name)
        if want not in questions[name]["criteria"]:
            die("routing.expect_label.%s: %r nao esta em criteria" % (name, want))

    fail_open = cfg.get("fail_open", True)
    if not isinstance(fail_open, bool):
        die("fail_open precisa ser booleano")

    label_human = routing.get("label_human", "jev:humano")
    label_ok = routing.get("label_ok", "jev:ok")
    for name, value in (("label_human", label_human), ("label_ok", label_ok)):
        if not isinstance(value, str) or not value.strip():
            die("routing.%s precisa ser string nao vazia" % name)

    control = validate_control(cfg.get("control"), questions)

    return {
        "version": 1,
        "model": model,
        "context": context,
        "questions": questions,
        "routing": {
            "human_below": human_below,
            "labels": labels,
            "expect_low": expect_low,
            "expect_label": expect_label,
            "label_human": label_human,
            "label_ok": label_ok,
        },
        "fail_open": fail_open,
        "control": control,
    }


# A control case is a state with a KNOWN answer. Everything here is declared by hand in
# the config and NEVER derived from the PR: a control assembled from the PR under
# judgement would move with it and stop being a control. An empty `control: []` is a
# config error, not an absence — absence is the key not being there at all, which is
# what the canonical line reports as `ausente`.
def validate_control(control, questions):
    if control is None:
        return []
    if not isinstance(control, list) or not control:
        die("control precisa ser uma lista nao vazia de casos (ou a chave ausente)")
    if len(control) > CONTROL_MAX:
        die(
            "control: no maximo %d casos (vieram %d); cada caso e UMA requisicao extra ao Jev"
            % (CONTROL_MAX, len(control))
        )
    seen = set()
    out = []
    for i, case in enumerate(control):
        if not isinstance(case, dict):
            die("control[%d] precisa ser um mapa" % i)
        unknown = [k for k in case if k not in CONTROL_KEYS]
        if unknown:
            die("control[%d]: chave(s) desconhecida(s): %s" % (i, ", ".join(sorted(unknown))))
        name = case.get("name")
        if not isinstance(name, str) or not CONTROL_NAME_RE.match(name):
            die("control[%d].name precisa casar [a-z0-9_]+ (veio %r)" % (i, name))
        if name in seen:
            die("control: nome repetido %r" % name)
        seen.add(name)
        state = case.get("state")
        if not isinstance(state, str) or not state.strip():
            die("control.%s.state precisa ser um texto FIXO nao vazio" % name)
        expect = case.get("expect")
        if not isinstance(expect, dict) or not expect:
            die("control.%s.expect precisa ser um mapa pergunta -> banda" % name)
        bands = {}
        for question, band in expect.items():
            if question not in questions:
                die("control.%s.expect: %r nao e uma pergunta declarada" % (name, question))
            if not isinstance(band, dict) or not band:
                die("control.%s.expect.%s precisa ser um mapa com min e/ou max" % (name, question))
            unknown = [k for k in band if k not in BAND_KEYS]
            if unknown:
                die(
                    "control.%s.expect.%s: chave(s) desconhecida(s): %s"
                    % (name, question, ", ".join(sorted(unknown)))
                )
            edges = {}
            for edge in BAND_KEYS:
                if edge not in band:
                    continue
                value = band[edge]
                if not isinstance(value, (int, float)) or isinstance(value, bool) or not 0 <= value <= 1:
                    die(
                        "control.%s.expect.%s.%s precisa ser numero entre 0 e 1 (veio %r)"
                        % (name, question, edge, value)
                    )
                edges[edge] = value
            if "min" in edges and "max" in edges and edges["min"] > edges["max"]:
                die(
                    "control.%s.expect.%s: min %s maior que max %s"
                    % (name, question, edges["min"], edges["max"])
                )
            bands[question] = edges
        out.append({"name": name, "state": state, "expect": bands})
    return out


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("uso: jev-config.py <caminho do acceptance.{yml,yaml,json}>\n")
        return 2
    path = argv[1]
    cfg = validate(load(path), path)
    json.dump(cfg, sys.stdout, ensure_ascii=False, sort_keys=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
