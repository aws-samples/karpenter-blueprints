# Website

This folder builds a static documentation site from the blueprint READMEs
and publishes it to GitHub Pages. The READMEs remain the single source of
truth: nothing here duplicates content.

## How it works

1. `sync_docs.py` copies the root README and every `blueprints/*/README.md`
   into `website/docs/` (git-ignored), rewriting repo-relative links so
   blueprint cross-references become site links and manifests point to
   GitHub. It also generates `robots.txt`, `llms.txt`, and `llms-full.txt`
   so the content is easy for search engines and LLMs to discover.
2. `mkdocs.yml` renders that tree with MkDocs Material, producing per-page
   titles, meta descriptions, canonical URLs, and a `sitemap.xml`.
3. `.github/workflows/deploy-docs.yml` runs both steps on every push to
   `main` and deploys the result to GitHub Pages.

## Local preview

```sh
pip install -r website/requirements.txt
python website/sync_docs.py
mkdocs serve -f website/mkdocs.yml
```

## Enabling GitHub Pages

In the repository settings, set Pages > Source to "GitHub Actions". The
workflow derives the site URL from the repository owner, so it works on
forks for testing as well as on the upstream repository.
