#!/usr/bin/env python3
"""
Extract the authoritative variable inventory from an OpenLane run.

Documentation goes stale; a run's own expanded config is ground truth for the
version that actually executed. Run this before trusting any variable name or
default from documentation (including this skill's reference files).

Usage:
    python3 config_inventory.py <run_dir_or_config.tcl> [--grep PATTERN]
    python3 config_inventory.py <run_dir> --check          # flag stale names
    python3 config_inventory.py <run_dir> --diff <other>   # compare two runs

<run_dir> is the directory containing config.tcl (OpenLane 1) or
resolved_config.json / config.json (OpenLane 2 / LibreLane).
"""

import json
import os
import re
import sys

# Names that were renamed or removed across OpenLane versions. If a config
# contains the old name, the run is older than the rename; if it contains
# neither, the variable may have been removed entirely.
# Renamed *within* the OpenLane 1.x line. If a config still uses the old name on
# a late 1.x release, it is genuinely stale -- nothing reads it.
RENAMES_OL1 = {
    "SYNTH_MAX_FANOUT": "MAX_FANOUT_CONSTRAINT",
    "SYNTH_MAX_TRAN": "MAX_TRANSITION_CONSTRAINT",
    "GLB_RT_ADJUSTMENT": "GRT_ADJUSTMENT",
    "GLB_RT_OVERFLOW_ITERS": "GRT_OVERFLOW_ITERS",
    "GLB_RT_ANT_ITERS": "GRT_ANT_ITERS",
    "GLB_RT_MAX_DIODE_INS_ITERS": "GRT_MAX_DIODE_INS_ITERS",
    "GLB_RT_ALLOW_CONGESTION": "GRT_ALLOW_CONGESTION",
    "GLB_RT_ESTIMATE_PARASITICS": "GRT_ESTIMATE_PARASITICS",
    "GLB_RT_LAYER_ADJUSTMENTS": "GRT_LAYER_ADJUSTMENTS",
    "GLB_RT_MACRO_EXTENSION": "GRT_MACRO_EXTENSION",
    "GLB_RT_MINLAYER": "RT_MIN_LAYER",
    "GLB_RT_MAXLAYER": "RT_MAX_LAYER",
    "CHECK_UNMAPPED_CELLS": "QUIT_ON_UNMAPPED_CELLS",
    "CHECK_ASSIGN_STATEMENTS": "QUIT_ON_ASSIGN_STATEMENTS",
    "TAP_DECAP_INSERTION": "RUN_TAP_DECAP_INSERTION",
    "FILL_INSERTION": "RUN_FILL_INSERTION",
    "RUN_ROUTING_DETAILED": "RUN_DRT",
    "SYNTH_CLOCK_UNCERTAINITY": "SYNTH_CLOCK_UNCERTAINTY",
    "FP_IO_HMETAL": "FP_IO_HLAYER",
    "FP_IO_VMETAL": "FP_IO_VLAYER",
    "ROUTING_OPT_ITERS": "DRT_OPT_ITERS",
}

# Deprecated in late 1.x AND some values now hard-error. Worse than a rename.
DEPRECATED_HARD = {
    "DIODE_INSERTION_STRATEGY":
        "GRT_REPAIR_ANTENNAS / RUN_HEURISTIC_DIODE_INSERTION / DIODE_ON_PORTS"
        "  [strategies 1, 2, 5 now HARD-ERROR]",
}

# Renamed only at the OpenLane 2 / LibreLane boundary. On OpenLane 1 the left-hand
# name is CORRECT and must not be reported as stale.
RENAMES_OL2 = {
    "GLB_RESIZER_SETUP_SLACK_MARGIN": "GRT_RESIZER_SETUP_SLACK_MARGIN",
    "GLB_RESIZER_HOLD_SLACK_MARGIN": "GRT_RESIZER_HOLD_SLACK_MARGIN",
    "GLB_RESIZER_TIMING_OPTIMIZATIONS": "GRT_RESIZER_TIMING_OPTIMIZATIONS",
    "GLB_RESIZER_SETUP_MAX_BUFFER_PERCENT": "GRT_RESIZER_SETUP_MAX_BUFFER_PCT",
    "GLB_RESIZER_HOLD_MAX_BUFFER_PERCENT": "GRT_RESIZER_HOLD_MAX_BUFFER_PCT",
    "PL_RESIZER_SETUP_MAX_BUFFER_PERCENT": "PL_RESIZER_SETUP_MAX_BUFFER_PCT",
    "PL_RESIZER_HOLD_MAX_BUFFER_PERCENT": "PL_RESIZER_HOLD_MAX_BUFFER_PCT",
    "CTS_CLK_BUFFER_LIST": "CTS_CLK_BUFFERS",
    "CLOCK_TREE_SYNTH": "RUN_CTS",
}

# Removed outright in late 1.x. Setting these does nothing.
REMOVED_IN_1_1 = ["CTS_TARGET_SKEW", "CELL_PAD", "LEC_ENABLE",
                  "SPEF_WIRE_MODEL", "SPEF_EDGE_CAP_FACTOR"]

# Variables whose value materially changes flow behaviour. Worth surfacing
# even when the caller didn't ask for them.
BEHAVIOUR_CRITICAL = [
    "QUIT_ON_SETUP_VIOLATIONS",
    "QUIT_ON_HOLD_VIOLATIONS",
    "QUIT_ON_TIMING_VIOLATIONS",
    "QUIT_ON_TR_DRC",
    "QUIT_ON_MAGIC_DRC",
    "QUIT_ON_KLAYOUT_DRC",
    "QUIT_ON_LVS_ERROR",
    "QUIT_ON_SYNTH_CHECKS",
    "QUIT_ON_UNMAPPED_CELLS",
    "QUIT_ON_XOR_ERROR",
    "QUIT_ON_LINTER_ERRORS",
    "RUN_CTS",
    "RUN_DRT",
    "RUN_LVS",
    "RUN_MAGIC_DRC",
    "RUN_KLAYOUT_DRC",
    "RUN_SPEF_EXTRACTION",
    "RUN_LINTER",
    "CLOCK_PORT",
    "CLOCK_PERIOD",
    "FP_SIZING",
    "FP_CORE_UTIL",
    "PL_TARGET_DENSITY",
    "SYNTH_STRATEGY",
    "STD_CELL_LIBRARY",
    "PDK",
]


def load(path):
    """Return {name: value} from an OpenLane 1 config.tcl or OL2 JSON config."""
    if not os.path.exists(path):
        sys.exit(f"error: no such file or directory: {path}")

    if os.path.isdir(path):
        for cand in ("config.tcl", "resolved_config.json", "config.json"):
            p = os.path.join(path, cand)
            if os.path.exists(p):
                path = p
                break
        else:
            sys.exit(
                f"error: no config.tcl / resolved_config.json / config.json in {path}\n"
                f"       point this at a run directory (the one containing config.tcl)"
            )

    text = open(path, encoding="utf-8", errors="replace").read()

    if path.endswith(".json"):
        try:
            raw = json.loads(text)
        except json.JSONDecodeError as e:
            sys.exit(f"error: {path} is not valid JSON: {e}")
        flat = {}
        for k, v in raw.items():
            flat[k] = json.dumps(v) if isinstance(v, (dict, list)) else str(v)
        if not flat:
            sys.exit(f"error: {path} contained no variables")
        return flat, path

    out = {}
    # [ \t] not \s -- \s matches newlines, so an empty value would
    # swallow the following line and drop that variable entirely.
    for m in re.finditer(r"^[ \t]*set[ \t]+::env\((\w+)\)[ \t]*(.*)$", text, re.M):
        out[m.group(1)] = m.group(2).strip().strip('"')
    if not out:
        sys.exit(
            f"error: no 'set ::env(...)' assignments found in {path}\n"
            f"       is this really an OpenLane 1 config.tcl?"
        )
    return out, path


def check(cfg, fmt):
    """Report stale names, removals, behaviour-critical values, and risky ranges."""
    is_ol2 = fmt == "json"
    print(f"# Detected format: {'OpenLane 2 / LibreLane (JSON)' if is_ol2 else 'OpenLane 1 (Tcl)'}")

    print("\n=== Deprecated settings ===")
    hit = False
    for old, new_name in DEPRECATED_HARD.items():
        if old in cfg:
            val = str(cfg[old]).strip()
            if old == "DIODE_INSERTION_STRATEGY":
                if val in ("1", "2", "5"):
                    print(f"  !! {old} = {val}  -- HARD-ERROR on OpenLane 1.1.x. "
                          f"This run cannot complete.")
                else:
                    print(f"  ~  {old} = {val}  -- deprecated; auto-converts on 1.1.x "
                          f"(values 1, 2, 5 would hard-error)")
                print(f"     -> set explicitly instead: GRT_REPAIR_ANTENNAS / "
                      f"RUN_HEURISTIC_DIODE_INSERTION / DIODE_ON_PORTS")
            else:
                print(f"  ~  {old} = {val}\n     -> {new_name}")
            hit = True
    if not hit:
        print("  none")

    print("\n=== Stale names (renamed within OpenLane 1; nothing reads these) ===")
    hit = False
    for old, new_name in RENAMES_OL1.items():
        if old in cfg:
            both = " (new name also set)" if new_name in cfg else ""
            print(f"  x  {old:38s} -> {new_name}{both}")
            hit = True
    if not hit:
        print("  none")

    if not is_ol2:
        print("\n=== Correct on OpenLane 1, renamed only in OL2/LibreLane ===")
        hit = False
        for old, new_name in RENAMES_OL2.items():
            if old in cfg:
                print(f"  ok {old:38s} (OL2 calls this {new_name})")
                hit = True
        if not hit:
            print("  none")

    print("\n=== Removed in OpenLane 1.1.x (setting these does nothing) ===")
    gone = [k for k in REMOVED_IN_1_1 if k in cfg]
    print("  " + (", ".join(gone) if gone else "none"))

    print("\n=== Behaviour-critical values ===")
    # A user-authored config lists only overrides, so almost everything reads as
    # "not present" and the real findings drown. An expanded run config has
    # hundreds of entries. Distinguish the two and report accordingly.
    sparse = len(cfg) < 60
    if sparse:
        print(f"  (sparse config — {len(cfg)} variables, so this looks like a "
              f"user-authored\n   config rather than an expanded run config. Unset "
              f"values below take the\n   tool's defaults, which are NOT shown here. "
              f"For ground truth, point this\n   script at a completed run directory.)\n")
    keys = BEHAVIOUR_CRITICAL if not is_ol2 else [
        k for k in BEHAVIOUR_CRITICAL
        if not k.startswith(("QUIT_ON_", "RUN_"))]
    shown = 0
    for k in keys:
        present = k in cfg
        if sparse and not present:
            continue  # don't list defaults we can't actually see
        v = str(cfg.get(k, "** not present **"))
        note = ""
        if k in ("QUIT_ON_SETUP_VIOLATIONS", "QUIT_ON_HOLD_VIOLATIONS",
                 "QUIT_ON_TIMING_VIOLATIONS") and v == "1":
            note = "  <-- flow ABORTS on timing violations"
        if k == "CLOCK_PORT":
            if v.strip() in ("", '""', "** not present **"):
                note = "  <-- NO CLOCK: STA uses a VIRTUAL clock; slack is not physical"
            elif len(v.split()) > 1:
                note = (f"  <-- {len(v.split())} CLOCK PORTS: OpenLane assumes ONE "
                        f"domain; declare the rest in SDC")
        print(f"  {k:34s} = {v[:48]}{note}")
        shown += 1
    if sparse and shown == 0:
        print("  (none of the behaviour-critical variables are set explicitly)")
    if is_ol2:
        print("  (QUIT_ON_* / RUN_* are OpenLane 1 concepts; OL2 controls this per step)")

    # Risky ranges -- utilization is the single most consequential number
    print("\n=== Range warnings ===")
    warns = []
    absolute = cfg.get("FP_SIZING") == "absolute"
    tiny = cfg.get("PL_RANDOM_GLB_PLACEMENT") == "1" or \
        cfg.get("PL_RANDOM_INITIAL_PLACEMENT") == "1"

    util = None
    try:
        util = float(cfg["FP_CORE_UTIL"])
    except (KeyError, ValueError):
        pass
    dens = None
    try:
        dens = float(cfg["PL_TARGET_DENSITY"])
    except (KeyError, ValueError):
        pass

    if util is not None and not absolute:
        if util >= 70:
            warns.append(f"FP_CORE_UTIL={util:g} is very high; expect congestion and "
                         f"routing failures. 35-50 is the sane band.")
        elif util >= 60:
            warns.append(f"FP_CORE_UTIL={util:g} is above the comfortable band "
                         f"(>60 risks congestion).")

    if dens is not None and dens >= 0.75 and not tiny:
        warns.append(f"PL_TARGET_DENSITY={dens:g} is very high; placement may "
                     f"diverge (GPL-0306).")

    if util is not None and dens is not None:
        if absolute:
            pass  # FP_CORE_UTIL is ignored under absolute sizing -- no coherence rule
        elif tiny:
            pass  # tiny designs intentionally pair low util with high density
        else:
            delta = dens - util / 100.0
            if not (0.01 <= delta <= 0.05):
                warns.append(f"PL_TARGET_DENSITY ({dens:g}) incoherent with "
                             f"FP_CORE_UTIL ({util:g}): delta {delta:+.3f}, want "
                             f"+0.01..+0.05. Common cause of placement divergence.")

    if absolute and "DIE_AREA" not in cfg:
        warns.append("FP_SIZING=absolute but DIE_AREA is unset.")

    # Macro vs core: a macro must leave met5 and the core ring to the parent.
    is_core = str(cfg.get("DESIGN_IS_CORE", "")).strip().lower()
    if is_core in ("0", "false"):
        top_layer = str(cfg.get("RT_MAX_LAYER", "")).strip().lower()
        if top_layer in ("met5", "5"):
            warns.append("DESIGN_IS_CORE=0 (macro) but RT_MAX_LAYER=met5. Macros must "
                         "stop at met4 and leave met5 for the parent's PDN straps and "
                         "top-level routing. Set RT_MAX_LAYER=met4.")
        if str(cfg.get("FP_PDN_CORE_RING", "")).strip() in ("1", "true"):
            warns.append("DESIGN_IS_CORE=0 (macro) but FP_PDN_CORE_RING=1. The core ring "
                         "belongs to the parent; set FP_PDN_CORE_RING=0 for a macro.")
    elif is_core in ("1", "true") and "MACRO_PLACEMENT_CFG" in cfg:
        if "FP_PDN_MACRO_HOOKS" not in cfg or not str(cfg["FP_PDN_MACRO_HOOKS"]).strip():
            warns.append("Core contains macros (MACRO_PLACEMENT_CFG set) but "
                         "FP_PDN_MACRO_HOOKS is empty. Macro power pins may end up "
                         "unconnected — a common cause of late, baffling LVS failures.")

    print("\n".join(f"  !  {w}" for w in warns) if warns else "  none")

    notes = []
    if absolute:
        notes.append("FP_SIZING=absolute: DIE_AREA governs and FP_CORE_UTIL is ignored, "
                     "so util/density coherence does not apply.")
    if tiny:
        notes.append("Random placement is enabled (tiny-design pattern): low utilization "
                     "with high target density is intentional here.")
    if notes:
        print("\n=== Context ===")
        for n in notes:
            print(f"  i  {n}")


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)

    cfg, path = load(args[0])
    fmt = "json" if path.endswith(".json") else "tcl"
    print(f"# Source: {path}")
    print(f"# Variables defined: {len(cfg)}\n")

    if "--check" in args:
        check(cfg, fmt)
    elif "--diff" in args:
        i = args.index("--diff")
        if i + 1 >= len(args):
            sys.exit("error: --diff requires a second run directory or config path")
        other, opath = load(args[i + 1])
        print(f"# Compared against: {opath}\n")
        keys = sorted(set(cfg) | set(other))
        diffs = [(k, cfg.get(k, "--"), other.get(k, "--")) for k in keys
                 if cfg.get(k, "--") != other.get(k, "--")]
        if not diffs:
            print("No differences.")
            return
        print(f"{'VARIABLE':40s} {'A':28s} {'B'}")
        print("-" * 100)
        for k, a, b in diffs:
            print(f"{k:40s} {a[:26]:28s} {b[:26]}")
        print(f"\n{len(diffs)} differing variable(s).")
    elif "--grep" in args:
        i = args.index("--grep")
        if i + 1 >= len(args):
            sys.exit("error: --grep requires a pattern")
        pat = args[i + 1].upper()
        hits = [k for k in sorted(cfg) if pat in k.upper()]
        if not hits:
            print(f"No variable name contains '{pat}'.")
            return
        for k in hits:
            print(f"{k:42s} = {cfg[k][:70]}")
    else:
        for k in sorted(cfg):
            print(f"{k:42s} = {cfg[k][:70]}")


if __name__ == "__main__":
    main()
