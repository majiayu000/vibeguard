#!/usr/bin/env python3
"""Package manager transparent correction: npm/yarn→pnpm, pip→uv.

Reads a shell command from stdin, prints the corrected command to stdout.
Prints empty string if no correction is needed.

Only rewrites simple single commands — chain commands (&&, ||, ;, pipes)
are not corrected to avoid mistakenly modifying complex pipelines.
"""
import sys
import re

cmd = sys.stdin.read().strip()
corrected = None

# Skip complex commands
if not re.search(r"&&|&|\|\||;|[|<>\n\r]|\$\(|`", cmd):

    # npm install (no parameters) → pnpm install
    if re.match(r"^npm\s+(?:install|i)\s*$", cmd):
        corrected = "pnpm install"

    # npm install/add <packages>
    elif re.match(r"^npm\s+(?:install|i|add)\s+", cmd):
        rest = re.sub(r"^npm\s+(?:install|i|add)\s+", "", cmd).strip()
        tokens = rest.split()

        KNOWN_FLAGS = {"--save-dev", "-D", "--save", "-S", "--save-optional", "-O", "--save-exact", "-E"}

        is_global = any(t in ("-g", "--global") or t.startswith("--location=global") for t in tokens)
        unknown_flags = [t for t in tokens if t.startswith("-") and t not in KNOWN_FLAGS]
        packages = [t for t in tokens if not t.startswith("-")]

        if packages and not is_global and not unknown_flags:
            pnpm_flags = []
            for t in tokens:
                if t in ("--save-dev", "-D"):
                    pnpm_flags.append("-D")
                elif t in ("--save-optional", "-O"):
                    pnpm_flags.append("-O")
                elif t in ("--save-exact", "-E"):
                    pnpm_flags.append("--save-exact")
            corrected = "pnpm add " + " ".join(pnpm_flags + packages).strip()

    # yarn install (no parameters) → pnpm install
    elif re.match(r"^yarn\s+install\s*$", cmd):
        corrected = "pnpm install"

    # yarn add <packages> → pnpm add <packages>
    elif re.match(r"^yarn\s+add\s+", cmd):
        rest = re.sub(r"^yarn\s+add\s+", "", cmd)
        tokens = rest.split()
        YARN_KNOWN_FLAGS = {"-D", "--dev", "--save-dev", "-O", "--optional",
                            "-E", "--exact", "-P", "--save-peer",
                            "-W", "--ignore-workspace-root-check"}
        packages = [t for t in tokens if not t.startswith("-")]
        unknown_flags = [t for t in tokens if t.startswith("-") and t not in YARN_KNOWN_FLAGS]
        if packages and not unknown_flags:
            pnpm_flags = []
            for t in tokens:
                if t in ("-D", "--dev", "--save-dev"):
                    pnpm_flags.append("-D")
                elif t in ("-O", "--optional"):
                    pnpm_flags.append("-O")
                elif t in ("-E", "--exact"):
                    pnpm_flags.append("--save-exact")
                elif t in ("-P", "--save-peer"):
                    pnpm_flags.append("--save-peer")
                elif t in ("-W", "--ignore-workspace-root-check"):
                    pnpm_flags.append("-w")
            corrected = "pnpm add " + " ".join(pnpm_flags + packages).strip()

    # pip install / pip3 install → uv pip install
    elif re.match(r"^pip3?\s+install\s+", cmd):
        rest = re.sub(r"^pip3?\s+install\s+", "", cmd)
        tokens = rest.split()
        PIP_KNOWN_FLAGS = {"-r", "--requirement", "-e", "--editable",
                           "-U", "--upgrade", "--pre", "--no-deps",
                           "-i", "--index-url", "--extra-index-url", "--no-index",
                           "-f", "--find-links", "-c", "--constraint",
                           "-v", "--verbose", "-q", "--quiet", "-t", "--target"}
        unknown_flags = [t for t in tokens if t.startswith("-") and t not in PIP_KNOWN_FLAGS]
        if not unknown_flags:
            corrected = "uv pip install " + rest

    # python -m pip install / python3 -m pip install → uv pip install
    elif re.match(r"^python3?\s+-m\s+pip\s+install\s+", cmd):
        rest = re.sub(r"^python3?\s+-m\s+pip\s+install\s+", "", cmd)
        tokens = rest.split()
        PIP_KNOWN_FLAGS = {"-r", "--requirement", "-e", "--editable",
                           "-U", "--upgrade", "--pre", "--no-deps",
                           "-i", "--index-url", "--extra-index-url", "--no-index",
                           "-f", "--find-links", "-c", "--constraint",
                           "-v", "--verbose", "-q", "--quiet", "-t", "--target"}
        unknown_flags = [t for t in tokens if t.startswith("-") and t not in PIP_KNOWN_FLAGS]
        if not unknown_flags:
            corrected = "uv pip install " + rest

print(corrected or "")
