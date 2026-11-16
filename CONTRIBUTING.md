# Contributing

An initiative by Bindubashini Boys’ 2015 & Friends.

## Git workflow

The initial commit records the complete local development baseline. Earlier edits were not committed individually, so this repository does not claim a reconstructed history.

Start each subsequent task from an up-to-date `main` and use a short-lived branch such as `codex/report-status-fix`. Keep commits focused on one coherent change, including its relevant tests and documentation. Use descriptive messages such as `fix: preserve report status after travel`.

```sh
git switch main
git pull --ff-only
git switch -c codex/your-change
```

Stage specific paths, inspect `git diff --cached`, and run `git diff --cached --check` before committing. Push the task branch and open a pull request describing the problem, resulting behavior, verification and remaining limitations. Wait for Application checks to pass before merging. Prefer a squash merge for one task and retain the PR discussion as review context. Do not rewrite shared history or force-push `main`.

Use the contributor's configured Git identity. Do not add assistant or tool co-author trailers. Keep the community signature and third-party license notices intact.

## What belongs in Git

Commit application/backend/admin source, tests, platform configuration, dependency manifests and lockfiles, brand masters and generated icons, documentation, and CI configuration. Update generated icon files together with their master using `python tools/generate_icons.py`.

Keep databases, real donor/seeker data, report evidence, screenshots from personal devices, build outputs, local environments, credentials, signing keys and agent runtime state out of Git. `.gitignore` protects these paths; never use `git add -f` to bypass those rules for private material. Public local demo credentials must be explicitly labelled and must never be reused for hosted services.

Before publishing, review the exact staged filenames and diff for secrets or personal data. Gitleaks can check the staged patch without including ignored local files:

```sh
git diff --cached --no-ext-diff --unified=0 | gitleaks stdin --redact=100
```

The baseline publication also used Gitleaks 8.30.1 against a copy of every candidate file. A clean scan is not a substitute for reviewing the content being published.

Give every module and named function a concise purpose comment. Explain why privacy checks, transaction locks, constraints, retry rules and non-obvious calculations exist. Keep comments synchronized with behavior; avoid comments that merely repeat an obvious assignment. Use descriptive test names to document the behavior being protected.

## Validation

After installing Node.js 24 LTS and the documented dependencies, run `./tools/check.ps1` on Windows. It starts the isolated local PostgreSQL container and runs JavaScript backend tests against the dedicated test database, admin tests, Flutter analysis and widget tests, stopping on failure. Other platforms can run the equivalent commands in the component READMEs. GitHub Actions repeats the checks on pushes and pull requests without production secrets or deployment permissions.

Build Android when changes affect native configuration, dependencies or packaged assets. Record relevant device checks and limitations in `docs/DELIVERY.md`. iOS compilation and device checks require macOS/Xcode; local Android success does not establish Apple-platform support.

Update `CHANGELOG.md` for meaningful user-visible milestones. Release tags and APK/App Store publication require a separately verified release; the initial development baseline is not a production release. Keep raw test/device evidence local and record reproducible commands and summarized results in the repository.
