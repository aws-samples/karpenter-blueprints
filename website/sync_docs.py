#!/usr/bin/env python3
"""Generate the MkDocs content tree from the repository READMEs.

The blueprint READMEs remain the single source of truth. This script copies
them into website/docs/ and adapts them for the website:

- Rewrites repo-relative links: blueprint cross-references become site links,
  links to code and manifests point to GitHub.
- Converts GitHub alert blockquotes (> [!NOTE]) into Material admonitions.
- Adds a title and meta description per page for search engines.
- Generates robots.txt, llms.txt, and llms-full.txt for crawlers and LLMs.

Run from anywhere: python3 website/sync_docs.py
The output directory (website/docs) is fully generated and git-ignored.
"""

import os
import posixpath
import re
import shutil
from pathlib import Path

WEBSITE_DIR = Path(__file__).resolve().parent
REPO_ROOT = WEBSITE_DIR.parent
OUT_DIR = WEBSITE_DIR / "docs"

GITHUB_URL = "https://github.com/aws-samples/karpenter-blueprints"
GITHUB_BRANCH = "main"
SITE_URL = os.environ.get(
    "SITE_URL", "https://aws-samples.github.io/karpenter-blueprints/"
).rstrip("/") + "/"

TITLE_PREFIX = "Karpenter Blueprint: "

# Inline markdown links, excluding images.
LINK_RE = re.compile(r"(?<!\!)\[([^\]]*)\]\(([^)\s]+)(\s+\"[^\"]*\")?\)")
ALERT_RE = re.compile(r"^>\s*\[!(\w+)\]\s*$")
ALERT_MAP = {
    "note": "note",
    "tip": "tip",
    "important": "info",
    "warning": "warning",
    "caution": "danger",
}


def github_url(repo_path: str) -> str:
    """Link to a file or directory on GitHub."""
    if repo_path in ("", "."):
        return GITHUB_URL
    kind = "blob" if "." in posixpath.basename(repo_path) else "tree"
    return f"{GITHUB_URL}/{kind}/{GITHUB_BRANCH}/{repo_path}"


def rewrite_target(target: str, src_dir: str) -> str:
    """Rewrite a link target from a README at repo path `src_dir`.

    Blueprint pages become site-relative links; everything else that lives in
    the repo becomes an absolute GitHub URL.
    """
    if target.startswith(("http://", "https://", "mailto:")) or target.startswith("#"):
        return target

    anchor = ""
    if "#" in target:
        target, anchor = target.split("#", 1)
        anchor = "#" + anchor

    # Tolerate the occasional `//blueprints/...` typo.
    while target.startswith("//"):
        target = target[1:]

    if target.startswith("/"):
        repo_path = posixpath.normpath(target.lstrip("/"))
    else:
        repo_path = posixpath.normpath(posixpath.join(src_dir, target))

    # `.` from the root README, or a path that escaped the repo root.
    if repo_path in (".", ".."):
        repo_path = ""

    # A blueprint linking to its own directory: point at GitHub so readers
    # can browse the manifests.
    if src_dir and repo_path == src_dir:
        return github_url(repo_path) + anchor

    # Repo root / root README -> site home page.
    if repo_path in ("", "README.md"):
        return ("../../index.md" if src_dir else "index.md") + anchor

    # Blueprint directory or its README -> blueprint page.
    m = re.fullmatch(r"blueprints/([^/]+)(?:/README\.md)?", repo_path)
    if m:
        name = m.group(1)
        prefix = "../" if src_dir else "blueprints/"
        return f"{prefix}{name}/index.md" + anchor

    # Everything else (manifests, cluster templates, LICENSE, ...) -> GitHub.
    return github_url(repo_path) + anchor


def transform(text: str, src_dir: str) -> str:
    """Rewrite links and convert GitHub alerts, skipping code fences."""
    out: list[str] = []
    lines = text.splitlines()
    in_fence = False
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.lstrip().startswith(("```", "~~~")):
            in_fence = not in_fence
            out.append(line)
            i += 1
            continue
        if not in_fence:
            m = ALERT_RE.match(line)
            if m:
                kind = ALERT_MAP.get(m.group(1).lower(), "note")
                out.append(f'!!! {kind} "{m.group(1).capitalize()}"')
                i += 1
                while i < len(lines) and lines[i].startswith(">"):
                    content = lines[i][1:]
                    if content.startswith(" "):
                        content = content[1:]
                    out.append(("    " + content).rstrip())
                    i += 1
                continue
            line = LINK_RE.sub(
                lambda m2: f"[{m2.group(1)}]({rewrite_target(m2.group(2), src_dir)}"
                f"{m2.group(3) or ''})",
                line,
            )
        out.append(line)
        i += 1
    return "\n".join(out) + "\n"


def extract_title(text: str) -> str:
    for line in text.splitlines():
        if line.startswith("# "):
            return line[2:].strip()
        if line.lstrip().startswith(("```", "~~~")):
            break
    return ""


def extract_description(text: str) -> str:
    """First prose paragraph for the meta description.

    Prefers the paragraph under '## Purpose' (every blueprint has one),
    falling back to the first prose after the H1.
    """
    lines = text.splitlines()
    starts = [
        next(
            (i for i, l in enumerate(lines) if re.match(pattern, l.strip())),
            None,
        )
        for pattern in (r"##\s+Purpose\b", r"#\s+\S")
    ]
    start = next((s for s in starts if s is not None), None)
    if start is None:
        return ""
    in_fence = False
    for line in lines[start + 1 :]:
        stripped = line.strip()
        if stripped.startswith(("```", "~~~")):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        if not stripped or stripped.startswith(("#", ">", "|", "<", "!", "-", "*")):
            continue
        # Strip markdown links and emphasis for plain text.
        plain = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", stripped)
        plain = re.sub(r"[*_`]", "", plain)
        if len(plain) > 160:
            plain = plain[:157].rsplit(" ", 1)[0] + "..."
        return plain
    return ""


def front_matter(title: str, description: str) -> str:
    lines = ["---"]
    if title:
        lines.append(f'title: "{title}"')
    if description:
        lines.append(f'description: "{description}"')
    lines.append("---")
    return "\n".join(lines) + "\n\n"


def main() -> None:
    if OUT_DIR.exists():
        shutil.rmtree(OUT_DIR)
    OUT_DIR.mkdir(parents=True)

    # Home page from the root README.
    root_readme = (REPO_ROOT / "README.md").read_text(encoding="utf-8")
    root_out = transform(root_readme, "")
    root_desc = extract_description(root_readme)
    (OUT_DIR / "index.md").write_text(
        front_matter("", root_desc) + root_out, encoding="utf-8"
    )

    # One page per blueprint.
    pages = []
    blueprints_dir = REPO_ROOT / "blueprints"
    for readme in sorted(blueprints_dir.glob("*/README.md")):
        name = readme.parent.name
        src_dir = f"blueprints/{name}"
        text = readme.read_text(encoding="utf-8")
        body = transform(text, src_dir)
        full_title = extract_title(text) or name
        nav_title = full_title.removeprefix(TITLE_PREFIX)
        description = extract_description(text)
        page_dir = OUT_DIR / "blueprints" / name
        page_dir.mkdir(parents=True)
        (page_dir / "index.md").write_text(
            front_matter(nav_title, description) + body, encoding="utf-8"
        )
        pages.append((name, nav_title, description, body))

    # Google Search Console ownership verification, if configured.
    # Set the GOOGLE_SITE_VERIFICATION repository variable to the token
    # from the "HTML file" verification method (e.g. google1234abcd).
    token = os.environ.get("GOOGLE_SITE_VERIFICATION", "").strip()
    if token:
        fname = token if token.endswith(".html") else f"{token}.html"
        (OUT_DIR / fname).write_text(
            f"google-site-verification: {fname}\n", encoding="utf-8"
        )

    # robots.txt
    (OUT_DIR / "robots.txt").write_text(
        f"User-agent: *\nAllow: /\n\nSitemap: {SITE_URL}sitemap.xml\n",
        encoding="utf-8",
    )

    # llms.txt: a compact index for LLM crawlers (https://llmstxt.org/).
    llms = [
        "# Karpenter Blueprints for Amazon EKS",
        "",
        "> Common workload scenarios (blueprints) showing how to configure "
        "Karpenter and Kubernetes objects on Amazon EKS, with deployment "
        "steps and expected results for each.",
        "",
        f"- [Overview]({SITE_URL}): what the blueprints are and how to use them",
        "",
        "## Blueprints",
        "",
    ]
    for name, title, description, _ in pages:
        suffix = f": {description}" if description else ""
        llms.append(f"- [{title}]({SITE_URL}blueprints/{name}/){suffix}")
    llms.append("")
    (OUT_DIR / "llms.txt").write_text("\n".join(llms), encoding="utf-8")

    # llms-full.txt: full content in one file for LLM ingestion.
    full = []
    for name, title, _, body in pages:
        full.append(f"<!-- {SITE_URL}blueprints/{name}/ -->")
        full.append(body.rstrip())
        full.append("\n---\n")
    (OUT_DIR / "llms-full.txt").write_text("\n".join(full), encoding="utf-8")

    print(f"Generated {1 + len(pages)} pages in {OUT_DIR}")


if __name__ == "__main__":
    main()
