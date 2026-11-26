#!/usr/bin/env python3
"""Verify committed generated sources against their coverage and provenance."""

from __future__ import annotations

import hashlib
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
COVERAGE = ROOT / "coverage"
INTEROP = ROOT / "src" / "Hosihikari.Binding.Bedrock.Interop" / "Generated"
SHIMS = ROOT / "native" / "BindingShim" / "generated"


def load(name: str) -> dict:
    with (COVERAGE / name).open(encoding="utf-8-sig") as stream:
        return json.load(stream)


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> int:
    provenance = load("provenance.json")
    baseline = load("baseline.json")
    summary = load("summary.json")

    if provenance["irVersion"] != summary["irVersion"]:
        fail("provenance.irVersion does not match coverage summary")
    if provenance["irManifestSha256"] != summary["irManifestSha256"]:
        fail("provenance.irManifestSha256 does not match coverage summary")
    if provenance["coverageManifestSha256"] != summary["manifestSha256"]:
        fail("provenance.coverageManifestSha256 does not match coverage summary")
    missing_configurations = set(provenance["configurations"]) - set(
        summary["configurations"]
    )
    if missing_configurations:
        fail(
            f"provenance configurations are not present in coverage summary: {sorted(missing_configurations)}"
        )

    if summary["declarations"]["bound"] < baseline["declarationsBound"]:
        fail("declaration bound count fell below baseline")
    if summary["members"]["bound"] < baseline["membersBound"]:
        fail("member bound count fell below baseline")

    functions = provenance["functions"]
    for configuration in provenance["configurations"]:
        shim = SHIMS / configuration / "bedrock"
        header = (shim / "binding_table.h").read_text(encoding="utf-8")
        source = (shim / "binding_table.cpp").read_text(encoding="utf-8")
        configuration_functions = header.count("(*hs_")
        if configuration_functions != functions:
            fail(
                f"{configuration} shim table has {configuration_functions} functions,"
                f" provenance says {functions}"
            )
        if functions < baseline["functions"]:
            fail("BindingShim function count fell below baseline")
        if f"std::uint32_t{{{provenance['tableVersion']}}}" not in source:
            fail(f"{configuration} shim table version does not match provenance")

    native_methods = (INTEROP / "NativeMethods.g.cs").read_text(encoding="utf-8")
    if "public delegate* unmanaged[Cdecl]<" not in native_methods:
        fail("NativeMethods.g.cs does not contain the managed table")
    if native_methods.count("public delegate* unmanaged[Cdecl]<") < functions:
        fail("managed table has fewer function pointers than the native table")

    generated_files = list(INTEROP.rglob("*.g.cs"))
    if len(generated_files) < 2:
        fail("generated Interop sources are missing")

    hash_manifest = COVERAGE / "generated.sha256"
    if not hash_manifest.is_file():
        fail("coverage/generated.sha256 is missing")
    entries: dict[str, str] = {}
    for line in hash_manifest.read_text(encoding="utf-8-sig").splitlines():
        if not line:
            continue
        digest, separator, relative = line.partition("  ")
        if not separator or len(digest) != 64:
            fail(f"invalid generated.sha256 line: {line}")
        entries[relative] = digest

    expected_paths = {path.relative_to(ROOT).as_posix() for path in generated_files}
    for configuration in provenance["configurations"]:
        shim = SHIMS / configuration / "bedrock"
        expected_paths.update(
            path.relative_to(ROOT).as_posix()
            for path in shim.iterdir()
            if path.is_file()
        )
    expected_paths.add("coverage/manifest.jsonl")
    expected_paths.add("coverage/summary.json")
    if set(entries) != expected_paths:
        missing = expected_paths - set(entries)
        extra = set(entries) - expected_paths
        fail(
            f"generated.sha256 path set mismatch (missing={sorted(missing)}, extra={sorted(extra)})"
        )

    for relative, digest in entries.items():
        path = ROOT / relative
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
        if actual != digest:
            fail(f"generated file hash mismatch: {relative}")

    print(
        "generated sources verified:"
        f" {functions} shim functions per configuration,"
        f" {summary['declarations']['bound']} bound declarations,"
        f" {summary['members']['bound']} bound members,"
        f" {len(generated_files)} generated C# files"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
