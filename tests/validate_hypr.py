#!/usr/bin/env python3
"""Run system/config/hypr/hyprland.lua against a mock `hl` API built from
Hyprland's own stubs (usr/share/hypr/stubs/hl.meta.lua) and fail on unknown
config keys, monitor/layer-rule fields or dispatchers.

usage: python tests/validate_hypr.py path/to/hl.meta.lua [profile]
"""
import re
import sys
from pathlib import Path

import lupa

ROOT = Path(__file__).resolve().parents[1]
stubs = Path(sys.argv[1]).read_text(encoding="utf8")
profile = sys.argv[2] if len(sys.argv) > 2 else "desktop"

config_keys = set(re.findall(r'^---\| "([a-z0-9_.:]+)"', stubs, re.M))
def fields(cls):
    m = re.search(rf"---@class {re.escape(cls)}\n((?:---@field .*\n)*)", stubs)
    return set(re.findall(r"---@field (\w+)", m.group(1))) if m else set()

monitor_fields = fields("HL.MonitorSpec")
layer_fields = fields("HL.LayerRuleSpec")
dsp = {"": fields("HL.DspNamespace")}
for ns in ("cursor", "group", "window", "workspace"):
    dsp[ns] = fields(f"HL.Dsp{ns.capitalize()}Namespace")
api = fields("HL.API") | set(re.findall(r"^function __HL_API\.(\w+)", stubs, re.M))

errors = []
L = lupa.LuaRuntime(unpack_returned_tuples=True)
lua_globals = L.globals()

def walk(tbl, prefix=""):
    for k, v in tbl.items():
        key = f"{prefix}{k}"
        if key in config_keys:
            continue
        if lupa.lua_type(v) == "table":
            walk(v, key + ".")
        else:
            errors.append(f"unknown config key: {key}")

def make_dsp(ns):
    t = L.table()
    for name in dsp[ns]:
        if name in dsp and name != "":
            continue
        t[name] = lambda *a, _n=name: f"dsp:{ns}.{_n}"
    return t

hl = L.table()
def config(t): walk(t)
def monitor(t):
    for k, _ in t.items():
        if k not in monitor_fields: errors.append(f"unknown monitor field: {k}")
def layer_rule(t):
    for k, _ in t.items():
        if k not in layer_fields: errors.append(f"unknown layer_rule field: {k}")
    return L.table()
def bind(keys, d, opts=None):
    if not (isinstance(d, str) and d.startswith("dsp:")) and lupa.lua_type(d) != "function":
        errors.append(f"bind {keys}: not a dispatcher ({d!r})")
    return L.table()
noop = lambda *a: L.table()
for name in api:
    hl[name] = noop
hl.config, hl.monitor, hl.layer_rule, hl.bind = config, monitor, layer_rule, bind
d = make_dsp("")
for ns in ("cursor", "group", "window", "workspace"):
    d[ns] = make_dsp(ns)
hl.dsp = d
lua_globals.hl = hl

# Lua that catches dispatchers that don't exist: index metamethod on dsp tables.
L.execute("""
local function strict(t, path)
  setmetatable(t, {__index = function(_, k) error("unknown dispatcher hl.dsp" .. path .. "." .. k, 2) end})
end
strict(hl.dsp, "")
for _, ns in ipairs({"cursor","group","window","workspace"}) do strict(hl.dsp[ns], "." .. ns) end
setmetatable(hl, {__index = function(_, k) error("unknown hl API: hl." .. k, 2) end})
""")

cfg = ROOT / "system/config/hypr"
tmp = ROOT / ".work/hypr-validate"
tmp.mkdir(parents=True, exist_ok=True)
(tmp / "colors.lua").write_text('return {bg="000000",surface="0d0c0a",overlay="1c1a16",fg="ebe3d2",muted="857d6e",accent="ebe3d2",accent2="c8412f",urgent="c8412f"}')
(tmp / "settings.lua").write_text(f'return {{profile="{profile}",resolution="1600x900@30",animations=true,kb_layout="us"}}')
L.execute(f'package.path = "{tmp.as_posix()}/?.lua;{cfg.as_posix()}/?.lua;" .. package.path')
try:
    L.execute((cfg / "hyprland.lua").read_text(encoding="utf8"))
except lupa.LuaError as e:
    errors.append(f"lua error: {e}")

if errors:
    print("\n".join(sorted(set(errors))))
    sys.exit(1)
print(f"hyprland.lua OK ({profile}): {len(config_keys)} known keys checked")
