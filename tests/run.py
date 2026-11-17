"""Loads the addon in Lua 5.1 against a stubbed WoW API and runs tests/spec.lua.

Usage:  python tests/run.py        (needs: pip install lupa)
"""
import pathlib
import sys

from lupa import lua51

ROOT = pathlib.Path(__file__).resolve().parent.parent
ADDON = ROOT  # the repository root is the addon folder


def main() -> int:
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    load = lua.eval(
        "function(source, name, ...) "
        "local chunk, err = loadstring(source, name) "
        "if not chunk then error(err, 0) end "
        "return chunk(...) end"
    )

    controls = load((ROOT / "tests" / "wowstub.lua").read_text(encoding="utf-8"), "@wowstub.lua")
    namespace = lua.eval("{}")
    lua.globals().T = controls
    lua.globals().ns = namespace

    # Load files in TOC order, exactly like the client does.
    toc = (ADDON / "BetterRareSpawns.toc").read_text(encoding="utf-8").splitlines()
    files = [line.strip() for line in toc if line.strip() and not line.startswith("#")]
    for relative in files:
        path = ADDON / relative.replace("\\", "/")
        if not path.exists():
            print(f"FAIL  TOC lists a missing file: {relative}")
            return 1
        load(path.read_text(encoding="utf-8"), "@" + relative, "BetterRareSpawns", namespace)

    listed = {f.replace("\\", "/") for f in files}
    on_disk = {
        p.relative_to(ADDON).as_posix()
        for folder in ("Core", "UI")
        for p in (ADDON / folder).rglob("*.lua")
    }
    for orphan in sorted(on_disk - listed):
        print(f"FAIL  Lua file not in the TOC: {orphan}")
        return 1

    failed = load((ROOT / "tests" / "spec.lua").read_text(encoding="utf-8"), "@spec.lua")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
