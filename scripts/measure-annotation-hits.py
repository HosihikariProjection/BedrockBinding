"""Measure how many annotated members actually exist in a run-time data file.

The carrier marks members `MCNAPI` (known but not exported) and `MCAPI`. Prelink
resolves the decorated names the shim would import against a `bedrock_runtime_data`
snapshot; that is the same lookup the game performs at load time, so the hit rate
says how many annotated members a caller could really reach.

The probe is a clang-cl object holding one reference per decorated name, plus a
table so nothing is optimised away. Names longer than MASM's 247-character
identifier limit rule out a masm probe, and clang-cl's `__asm__` label alias is
the only route that accepts them.

Usage:
    python scripts/measure-annotation-hits.py <header-ir-dir> <bedrock_runtime_data> [--macro MCNAPI]
"""

import argparse
import pathlib
import re
import subprocess
import sys
import tempfile

CLANG_CL = pathlib.Path(r"C:\Program Files\LLVM\bin\clang-cl.exe")
PRELINK = pathlib.Path.home() / (
    r"AppData\Local\.xmake\packages\p\prelink\v0.8.8"
    r"\016d4eca850f4c46831153d6f93c5931\bin\prelink.exe"
)


def names_for(shard: pathlib.Path, macro: str) -> list[str]:
    seen: dict[str, None] = {}
    for line in shard.read_text(encoding="utf-8").splitlines():
        record = __import__("json").loads(line)
        if record.get("recordType") != "member":
            continue
        mangled = record.get("mangledName")
        if not mangled:
            continue
        if any(item.get("name") == macro for item in record.get("macros") or []):
            seen[mangled] = None
    return list(seen)


def build_probe(directory: pathlib.Path, names: list[str]) -> pathlib.Path:
    source = directory / "probe.cpp"
    lines = [f'extern "C" void f{index}() __asm__("{name}");' for index, name in enumerate(names)]
    lines.append("extern \"C\" void* const hs_tbl[] = {"
                 + ",".join(f"(void*)&f{index}" for index in range(len(names))) + "};")
    lines.append("extern \"C\" int hs_probe() { return (int)sizeof(hs_tbl); }")
    source.write_text("\n".join(lines) + "\n", encoding="utf-8")

    obj = directory / "probe.obj"
    result = subprocess.run(
        [str(CLANG_CL), "/nologo", "/c", f"/Fo{obj}", str(source)],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        sys.exit(result.stdout + result.stderr)
    return obj


def prelink_names(obj: pathlib.Path, data: pathlib.Path, output: pathlib.Path) -> set[str]:
    (output / "lib").mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [str(PRELINK), "server-windows-x64", str(output), str(data), str(obj)],
        check=True,
        capture_output=True,
    )
    library = (output / "lib" / "bedrock_runtime_api.lib").read_bytes()
    return {match.decode("latin1") for match in re.findall(rb"\?[^\x00]+", library)}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("ir", type=pathlib.Path)
    parser.add_argument("data", type=pathlib.Path)
    parser.add_argument("--macro", default="MCNAPI")
    arguments = parser.parse_args()

    shard = arguments.ir / "shard.jsonl"
    names = names_for(shard, arguments.macro)
    if not names:
        sys.exit(f"no {arguments.macro} members with a decorated name in {shard}")

    with tempfile.TemporaryDirectory() as raw:
        directory = pathlib.Path(raw)
        obj = build_probe(directory, names)
        resolved = prelink_names(obj, arguments.data, directory / "out")

    hits = sorted(set(names) & resolved)
    print(f"{arguments.macro}: {len(hits)} of {len(names)} resolve "
          f"({len(hits) / len(names) * 100:.2f}%) in {arguments.data}")
    for name in hits[:20]:
        print(f"  {name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
