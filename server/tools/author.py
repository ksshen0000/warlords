"""Dev-time content authoring with an LLM. The shipped game never runs this; it only reads content/*.toml.

    python -m tools.author gen dialogue [--topic greet] [--culture zhou] [--n 3]
        draft lines for every cell of content/spec/dialogue.toml -> content/drafts/dialogue_<topic>.toml
    python -m tools.author review dialogue_greet [--all]
        an LLM editor reads each draft line against its situation: keep / rewrite / drop (with a reason);
        the draft is rewritten in place and the decisions are logged to content/drafts/<name>.review.md
    python -m tools.author check
        validate content/*.toml and content/drafts/*.toml (placeholders, length, banned words)
    python -m tools.author accept dialogue_greet
        move a reviewed draft into content/ (merged with what's there, duplicates dropped)
    python -m tools.author stats
        how many lines each (topic, situation, culture) cell has

Workflow: gen -> review -> read and edit the draft (delete weak lines, fix wording) -> check -> accept.
The LLM key comes from server/local.toml like the game's own LLM tiers.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tomllib
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONTENT = os.path.join(ROOT, "content")
SPEC = os.path.join(CONTENT, "spec")
DRAFTS = os.path.join(CONTENT, "drafts")
WORLD_DOC = os.path.join(os.path.dirname(ROOT), "docs", "worldbuilding.md")

COMMON_VARS = {"name", "kingdom", "ruler", "ruler_title", "culture", "here"}
CULTURES = ["zhou", "yan", "zhao", "liang", "shu", "rou"]
# real dynasties, peoples and people of the period: the world is fictional (docs/worldbuilding.md)
BANNED = ["晋", "前燕", "后燕", "后赵", "前秦", "后秦", "北魏", "刘宋", "南朝", "北朝", "十六国", "五胡",
          "鲜卑", "匈奴", "羯", "氐", "羌", "柔然", "拓跋", "慕容", "宇文", "司马", "石勒", "石虎", "苻坚", "刘渊",
          "桓温", "谢安", "王导", "祖逖", "冉闵", "王猛",
          "OK", "ok", "哈哈", "没问题", "好的", "兄弟们", "老铁", "搞定"]
RULER_WORDS = re.compile(r"(?<![城军])(朕|本王|本单于)|孤(?![城军身儿寡苦独立零陋])")


def _toml_str(s: str) -> str:
    return json.dumps(s, ensure_ascii=False)


def _dump_lines(lines: list[dict], header: str = "") -> str:
    out = [header] if header else []
    for ln in lines:
        out.append("[[line]]")
        for k in ("topic", "culture", "when", "priority", "weight"):
            if k in ln and ln[k] not in (None, [], 0, ""):
                v = ln[k]
                out.append(f"{k} = " + (json.dumps(v, ensure_ascii=False) if isinstance(v, list) else
                                        _toml_str(v) if isinstance(v, str) else str(v)))
        if ln.get("warn"):
            out.append("# ⚠ " + "；".join(ln["warn"]))
        out.append(f"text = {_toml_str(ln['text'])}")
        out.append("")
    return "\n".join(out)


def _read(path: str) -> dict:
    with open(path, "rb") as f:
        return tomllib.load(f)


def _section(doc: str, start: str, end: str | None) -> str:
    i = doc.index(start)
    j = doc.index(end, i) if end else len(doc)
    return doc[i:j].strip()


# ------------------------------------------------------------------ validation
def problems(ln: dict, cell_vars: set[str] | None = None) -> tuple[list[str], list[str]]:
    """(errors that reject the line, warnings for the reviewer)."""
    t = ln.get("text", "")
    errs, warns = [], []
    used = set(re.findall(r"\{(\w+)\}", t))
    allowed = COMMON_VARS | (cell_vars if cell_vars is not None else
                             {"enemy", "siege", "fief", "target", "place"})
    if ln.get("topic") in ("hideout", "bandits", "letter", "goods"):          # content/quests.toml
        allowed = {"town", "lair", "band", "target", "target_kingdom", "good", "qty", "bonus"}
    if used - allowed:
        errs.append("未知占位符 " + "、".join(sorted(used - allowed)))
    if re.search(r"\{[^}]*$|^[^{]*\}", t):
        errs.append("花括号不成对")
    n = len(re.sub(r"\{\w+\}", "某某", t))
    if n < 4 or n > 80:
        errs.append(f"长度 {n}（应为 4–80 字）")
    for b in BANNED:
        if b in t:
            errs.append(f"禁用词「{b}」")
    if "ruler" not in " ".join(ln.get("when", [])).replace("ruler_rel", "") and RULER_WORDS.search(t):
        warns.append("非君主台词里有君主自称")
    if "末将" in t and "status=vassal" not in ln.get("when", []):
        warns.append("对外人自称「末将」")
    return errs, warns


def cmd_check(_args) -> int:
    bad = 0
    for d in (CONTENT, DRAFTS):
        if not os.path.isdir(d):
            continue
        for fn in sorted(os.listdir(d)):
            if not fn.endswith(".toml"):
                continue
            for ln in _read(os.path.join(d, fn)).get("line", []):
                errs, warns = problems(ln)
                for e in errs + warns:
                    print(f"{'✗' if e in errs else '⚠'} {os.path.relpath(os.path.join(d, fn), ROOT)} "
                          f"[{ln.get('topic')}/{ln.get('culture', '-')}] {e}：{ln.get('text')}")
                bad += len(errs)
    print("检查完毕：" + (f"{bad} 处错误" if bad else "没有错误"))
    return 1 if bad else 0


# ------------------------------------------------------------------ generation
def _system(spec: dict) -> str:
    doc = open(WORLD_DOC, encoding="utf-8").read()
    world = "\n\n".join([_section(doc, "## 1. 一句话", "## 2."), _section(doc, "## 4. 六国", "## 5."),
                         _section(doc, "## 10. LLM 角色语言风格", "## 11.")])
    return f"""你是一款架空历史战略游戏的中文编剧，为游戏里的将军和君主写台词。台词会被游戏按情形挑选、原样显示，不会再经过人工改写。

{world}

写作要求：
- 每句是说话人对玩家（一支小部队的首领）当面说的一句话，15–45 字为宜，最多 60 字。
- 半文半白：句子短，可用「足下」「阁下」「尔」「吾」「某」，不用现代口语和网络用语，也不要整段古文。
- 称呼玩家用「足下」「阁下」「你」「尔」等，不要编造玩家的名字。
- 除非情形说明「说话人是君主」，说话人就是普通将军：不要用「朕」「孤」「本王」，对外人也不要自称「末将」。
- 只能用情形里列出的占位符（原样写，如 {{enemy}}），不要编造其他具体的人名、城名、数字。
- 占位符的含义要用对：{{name}} 是说话人自己（不是玩家）；{{kingdom}} 是说话人自己的国家；{{here}} 是说话人此刻所在的地方，
  不是玩家去过的地方。
- 同一格的几句要彼此不同：角度、语气、长短都要有变化；要有这个国家的味道，但别每句都把国名挂在嘴上。
- 只输出 JSON。"""


def _user(cells: list[dict], culture: str | None, n: int, voice: dict) -> str:
    who = (f"说话人是{voice[culture]}的人。" if culture else "这是通用台词：不带明显的国家口吻，哪国的将军说都不违和。")
    parts = [who, f"为下面每一格各写 {n} 句不同的台词。", ""]
    for i, c in enumerate(cells):
        vars_ = sorted(COMMON_VARS | set(c.get("vars", [])))
        parts.append(f"格 c{i}：{c['brief']}\n  可用占位符：" + "、".join("{" + v + "}" for v in vars_))
    parts.append("")
    parts.append('输出格式：{"c0": ["……", "……"], "c1": [...], ...}')
    return "\n".join(parts)


def cmd_gen(args) -> int:
    from warlords.brains import make_llm
    from warlords.rules import RULES
    spec = _read(os.path.join(SPEC, f"{args.kind}.toml"))
    n = args.n or int(spec.get("lines_per_cell", 3))
    voice = spec.get("voice", {})
    cells = [c for c in spec["cell"] if not args.topic or c["topic"] in args.topic.split(",")]
    if args.cond:
        cells = [c for c in cells if args.cond in c.get("when", [])]
    cultures = [None] + [c for c in CULTURES if not args.culture or c in args.culture.split(",")]
    if args.culture:
        cultures = [c for c in cultures if c]
    llm = make_llm(RULES.llm_setting("provider") or "deepseek")
    system = _system(spec)
    by_topic: dict[str, list[dict]] = {}
    for c in cells:
        by_topic.setdefault(c["topic"], []).append(c)
    jobs = [(t, cs, cu) for t, cs in by_topic.items() for cu in cultures]
    print(f"{len(jobs)} 次请求（{len(by_topic)} 个话题 × {len(cultures)} 种口吻），模型 {llm.model}")

    def run(job):
        topic, cs, cu = job
        for _attempt in range(2):
            data = llm.chat_json(system, _user(cs, cu, n, voice))
            if isinstance(data, dict):
                return job, data
        return job, None

    out: dict[str, list[dict]] = {}
    rejected = 0
    with ThreadPoolExecutor(max_workers=8) as pool:
        for (topic, cs, cu), data in pool.map(run, jobs):
            if data is None:
                print(f"  ✗ {topic}/{cu or '通用'}：请求失败")
                continue
            for i, c in enumerate(cs):
                for text in data.get(f"c{i}", [])[: n + 1]:
                    ln = {"topic": topic, "culture": cu, "when": c.get("when", []),
                          "priority": c.get("priority", 0), "text": str(text).strip()}
                    errs, warns = problems(ln, set(c.get("vars", [])))
                    need = [v for v in c.get("require", []) if "{" + v + "}" not in ln["text"]]
                    if need:
                        errs.append("缺少占位符 " + "、".join(need))
                    if errs:
                        rejected += 1
                        print(f"  ✗ 退回 [{topic}/{cu or '通用'}] {'；'.join(errs)}：{ln['text']}")
                        continue
                    ln["warn"] = warns
                    out.setdefault(topic, []).append(ln)
    os.makedirs(DRAFTS, exist_ok=True)
    for topic, lines in out.items():
        path = os.path.join(DRAFTS, f"{args.kind}_{topic}.toml")
        old = _read(path).get("line", []) if os.path.exists(path) and not args.replace else []
        seen = {o["text"] for o in old}
        lines = old + [ln for ln in lines if ln["text"] not in seen]
        lines.sort(key=lambda x: (x.get("culture") or "", json.dumps(x.get("when", []))))
        with open(path, "w", encoding="utf-8") as f:
            f.write(_dump_lines(lines, f"# 草稿：{topic}（tools/author.py 生成，待审阅：删掉不好的句子、改措辞，然后 accept）\n"))
        print(f"  → {os.path.relpath(path, ROOT)}：{len(lines)} 句")
    print(f"退回 {rejected} 句")
    return 0


REVIEW_SYSTEM = """你是这款游戏的文字总编，负责审定编剧写的台词。台词由游戏按情形自动挑选、原样显示给玩家。

{world}

逐句审查，标准（按重要性）：
1. 合不合情形：必须符合这一格的情形说明；说话人的身份（将军还是君主）、和玩家的关系要对。
2. 不许诺游戏里没有的事：台词不能邀请玩家入伙、随军、领兵，不能命令玩家去做事（君主对自己的臣子除外），
   不能许给钱粮官职，不能说出具体的数目、人名、城名（占位符除外）。台词只是表态和透露消息。
3. 口吻：半文半白、简短；要有这个国家的味道和人物的性格；不要现代俗语、网络用语、现代比喻。
4. 不空洞：要有态度或信息，最好有一点具体的生活细节。
5. 同一格里不要雷同（句式、开头、意思重复的只留最好的）。

「某」「吾」「我」「在下」「老夫」都是合格的自称，「足下」「阁下」「你」「尔」都是合格的称呼，不要只为换称谓而改。
只有违反上面标准时才 edit 或 drop；没毛病的句子一律 keep，不要为了「更好」做小修小补。
对每一句给出决定：keep（原样保留）、edit（给出改好的句子，占位符原样保留）、drop（删掉）。
宁缺毋滥：每一格最后留下 2–3 句好的就够了。
只输出 JSON：{{"r": [{{"i": 0, "d": "keep"}}, {{"i": 1, "d": "edit", "t": "改好的句子", "why": "理由"}}, {{"i": 2, "d": "drop", "why": "理由"}}]}}"""


def cmd_review(args) -> int:
    from warlords.brains import make_llm
    from warlords.rules import RULES
    spec = _read(os.path.join(SPEC, "dialogue.toml"))
    briefs = {(c["topic"], json.dumps(c.get("when", []))): c for c in spec["cell"]}
    voice = spec.get("voice", {})
    names = ([fn[:-5] for fn in sorted(os.listdir(DRAFTS)) if fn.endswith(".toml")] if args.all else [args.name])
    llm = make_llm(RULES.llm_setting("provider") or "deepseek")
    llm.token_kw["max_tokens"] = 16000
    llm.token_kw["extra_body"] = {"thinking": {"type": "enabled"}}     # editing is worth the slower, careful pass
    doc = open(WORLD_DOC, encoding="utf-8").read()
    system = REVIEW_SYSTEM.format(world=_section(doc, "## 10. LLM 角色语言风格", "## 11."))
    for name in names:
        path = os.path.join(DRAFTS, name + ".toml")
        lines = _read(path).get("line", [])
        groups: dict[tuple, list[int]] = {}
        for i, ln in enumerate(lines):
            groups.setdefault((ln.get("culture"), ln["topic"], json.dumps(ln.get("when", []))), []).append(i)

        def run(item):
            (cu, topic, when), idx = item
            c = briefs.get((topic, when), {})
            who = voice.get(cu, "通用台词（不分国家口吻）") if cu else "通用台词（不分国家口吻）"
            body = "\n".join(f"{k}. {lines[i]['text']}" for k, i in enumerate(idx))
            user = (f"话题：{topic}\n情形：{c.get('brief', '')}\n口吻：{who}\n"
                    f"可用占位符：{'、'.join('{' + v + '}' for v in sorted(COMMON_VARS | set(c.get('vars', []))))}\n\n"
                    f"台词：\n{body}")
            for _ in range(2):
                data = llm.chat_json(system, user)
                if isinstance(data, dict) and isinstance(data.get("r"), list):
                    return item, data["r"]
            return item, None

        keep: list[dict] = []
        log = [f"# 审稿记录：{name}\n"]
        stats = {"keep": 0, "edit": 0, "drop": 0, "fail": 0}
        with ThreadPoolExecutor(max_workers=8) as pool:
            for ((cu, topic, when), idx), res in pool.map(run, groups.items()):
                log.append(f"\n## {topic} · {cu or '通用'} · {when}\n")
                if res is None:
                    stats["fail"] += len(idx)
                    keep += [lines[i] for i in idx]
                    log.append("（审稿失败，原样保留）")
                    continue
                dec = {int(r.get("i", -1)): r for r in res if isinstance(r, dict)}
                for k, i in enumerate(idx):
                    ln, r = dict(lines[i]), dec.get(k, {"d": "keep"})
                    d = r.get("d", "keep")
                    if d == "edit" and r.get("t"):
                        new = dict(ln, text=str(r["t"]).strip())
                        if problems(new, set(briefs.get((topic, when), {}).get("vars", [])))[0]:
                            d = "keep"
                        else:
                            log.append(f"- ✎ {ln['text']}\n  → {new['text']}（{r.get('why', '')}）")
                            ln = new
                    if d == "drop":
                        log.append(f"- ✗ {ln['text']}（{r.get('why', '')}）")
                        stats["drop"] += 1
                        continue
                    stats["edit" if d == "edit" else "keep"] += 1
                    ln.pop("warn", None)
                    ln["warn"] = problems(ln)[1]
                    keep.append(ln)
        keep.sort(key=lambda x: (x.get("culture") or "", json.dumps(x.get("when", []), ensure_ascii=False)))
        with open(path, "w", encoding="utf-8") as f:
            f.write(_dump_lines(keep, f"# 草稿：{name}（已经过 LLM 审稿，待人工过目后 accept）\n"))
        with open(os.path.join(DRAFTS, name + ".review.md"), "w", encoding="utf-8") as f:
            f.write("\n".join(log) + "\n")
        print(f"{name}：保留 {stats['keep']}，改写 {stats['edit']}，删除 {stats['drop']}"
              + (f"，审稿失败 {stats['fail']}" if stats["fail"] else "") + f" → 剩 {len(keep)} 句")
    return 0


def cmd_accept(args) -> int:
    src = os.path.join(DRAFTS, args.name + ".toml")
    dst = os.path.join(CONTENT, args.name + ".toml")
    new = _read(src).get("line", [])
    bad = [ln for ln in new if problems(ln)[0]]
    if bad:
        print(f"草稿里还有 {len(bad)} 句有错误，先运行 check 修好")
        return 1
    old = _read(dst).get("line", []) if os.path.exists(dst) else []
    seen = {o["text"] for o in old}
    lines = old + [ln for ln in new if ln["text"] not in seen]
    lines.sort(key=lambda x: (x.get("culture") or "", json.dumps(x.get("when", []), ensure_ascii=False)))
    with open(dst, "w", encoding="utf-8") as f:
        f.write(_dump_lines(lines, f"# 台词：{args.name}（已审阅；格式见 warlords/content.py）\n"))
    os.remove(src)
    print(f"已并入 {os.path.relpath(dst, ROOT)}：共 {len(lines)} 句（新增 {len(lines) - len(old)}）")
    return 0


def cmd_stats(_args) -> int:
    spec = _read(os.path.join(SPEC, "dialogue.toml"))
    lines = []
    for fn in sorted(os.listdir(CONTENT)):
        if fn.startswith("dialogue") and fn.endswith(".toml"):
            lines += _read(os.path.join(CONTENT, fn)).get("line", [])
    print(f"{'话题':<12}{'情形':<34}" + "".join(f"{c or '通用':>6}" for c in [None] + CULTURES))
    for c in spec["cell"]:
        row = [sum(1 for ln in lines if ln["topic"] == c["topic"] and ln.get("when", []) == c.get("when", [])
                   and ln.get("culture") == cu) for cu in [None] + CULTURES]
        print(f"{c['topic']:<12}{' '.join(c.get('when', [])) or '（默认）':<34}" + "".join(f"{x:>6}" for x in row))
    print(f"共 {len(lines)} 句")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("gen")
    g.add_argument("kind", nargs="?", default="dialogue")
    g.add_argument("--topic")
    g.add_argument("--culture")
    g.add_argument("--n", type=int)
    g.add_argument("--cond", help="only cells whose conditions include this one, e.g. ruler")
    g.add_argument("--replace", action="store_true", help="overwrite existing drafts instead of adding to them")
    r = sub.add_parser("review")
    r.add_argument("name", nargs="?")
    r.add_argument("--all", action="store_true")
    sub.add_parser("check")
    a = sub.add_parser("accept")
    a.add_argument("name")
    sub.add_parser("stats")
    args = ap.parse_args()
    return {"gen": cmd_gen, "review": cmd_review, "check": cmd_check, "accept": cmd_accept, "stats": cmd_stats}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
