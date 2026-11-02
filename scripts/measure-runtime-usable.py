"""Count members that are callable on a live server, not just projectable.

A member is runtime-usable when it is not an emitted stub and every shim function
its generated body calls can actually be reached:

  * local shim functions (field/offset access, bitfields, no-symbol destructors)
    need no game symbol;
  * an external function needs its decorated name to resolve in the server's
    runtime data;
  * a virtual function may fall back to the object's vtable slot, so it is
    usable even when the symbol is missing (it still needs a live object).

Usage:
    python scripts/measure-runtime-usable.py <generated-dir> <binding_table.cpp> <unresolved.txt>
"""

import pathlib
import re
import sys

member_start = re.compile(r"^    public ")
noise = ("public void Dispose()", "public nint Handle =>")
hs_token = re.compile(r"\b(hs_\w+)(?=\()")
shim_start = re.compile(r"^static .* (hs_\w+)\(.*\) try$")
resolve = re.compile(r'hs_resolve\(std::uintptr_t\{0\}, "((?:[^"\\]|\\.)*)"\)')
stub_reason = re.compile(r'BindingShim cannot project this member: (.*?)\.?"')


def read_shim(path):
    """Map every emitted shim function to its reachability."""
    functions = {}
    name = None
    body = []

    def finish():
        text = "\n".join(body)
        if "hs_vtable[" in text:
            functions[name] = ("virtual", [], True)
            return
        symbols = resolve.findall(text)
        if not symbols:
            functions[name] = ("local", [], True)
            return
        functions[name] = ("external", symbols, None)

    for line in pathlib.Path(path).read_text(encoding="utf-8").splitlines():
        if name is None:
            match = shim_start.match(line)
            if match:
                name = match.group(1)
                body = []
            continue
        if line == "}":
            finish()
            name = None
            continue
        body.append(line)
    return functions


def is_stub(lines, index):
    window = "\n".join(lines[max(0, index - 2) : index + 4])
    return "NotSupportedException" in window and "Obsolete" in "\n".join(lines[max(0, index - 2) : index])


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        return 2

    generated = pathlib.Path(sys.argv[1])
    functions = read_shim(sys.argv[2])
    unresolved = {
        line.strip()
        for line in pathlib.Path(sys.argv[3]).read_text(encoding="utf-8").splitlines()
        if line.strip()
    }

    for name, (kind, symbols, usable) in functions.items():
        if kind == "external":
            functions[name] = (kind, symbols, all(symbol not in unresolved for symbol in symbols))

    counts = {
        "members": 0,
        "stubs": 0,
        "usable": 0,
        "blocked": 0,
        "no_shim_call": 0,
    }
    blocked_examples = []

    for path in sorted(generated.glob("*.g.cs")):
        lines = path.read_text(encoding="utf-8").splitlines()
        starts = [index for index, line in enumerate(lines) if member_start.match(line)]
        for position, start in enumerate(starts):
            line = lines[start]
            if line.strip().startswith("public static ") and " Borrow(" in line:
                continue
            if re.match(r"^    public \w+\(nint handle\)", line):
                continue
            if line.strip() in noise:
                continue
            if re.match(r"^    public (?:static )?\w+ $", line):
                # A property's declaration line is followed by its accessors; treat the
                # declaration as the member and stop at the next member start.
                pass

            end = starts[position + 1] if position + 1 < len(starts) else len(lines)
            body = "\n".join(lines[start:end])
            if is_stub(lines, start):
                counts["stubs"] += 1
                continue

            counts["members"] += 1
            tokens = sorted(set(hs_token.findall(body)))
            if not tokens:
                counts["no_shim_call"] += 1
                counts["usable"] += 1
                continue

            missing = [token for token in tokens if not functions.get(token, ("?", [], False))[2]]
            if missing:
                counts["blocked"] += 1
                if len(blocked_examples) < 8:
                    blocked_examples.append((path.stem, missing[:3]))
            else:
                counts["usable"] += 1

    non_stub = counts["usable"] + counts["blocked"]
    print(f"members counted: {counts['members']}")
    print(f"  stubs:         {counts['stubs']}")
    print(f"  non-stub:      {non_stub} (usable {counts['usable']}, blocked {counts['blocked']})")
    print(f"  no shim call:  {counts['no_shim_call']} (compile-time constants; counted usable)")
    print(
        "runtime-usable share:"
        f" {counts['usable'] / max(1, non_stub):.1%} of non-stub,"
        f" {counts['usable'] / max(1, counts['members'] + counts['stubs']):.1%} of emitted members"
    )
    if blocked_examples:
        print("blocked examples:")
        for name, tokens in blocked_examples:
            print(f"  {name}: {', '.join(tokens)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
