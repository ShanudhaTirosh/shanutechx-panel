# ShanuTechX Panel — GitHub Setup & Build Guide

Everything you need to go from the patch zip to a live GitHub repository that
automatically compiles and publishes release binaries whenever you push a tag.

---

## Overview of the pipeline

```
Your laptop / VPS
       │
       ▼
  Git push tag "v1.0.0"
       │
       ▼
  GitHub Actions
  ├── npm ci && npm run build          (React + Vite frontend)
  ├── go build -ldflags "..." main.go  (Go backend, 4 arches in parallel)
  ├── Downloads Xray-core + geo-data
  ├── Packages shanutechx-linux-amd64.tar.gz (and arm64, armv7, 386)
  └── Creates a GitHub Release with the tarballs attached
       │
       ▼
  shanutechx-install.sh on your VPS
  └── wget shanutechx-linux-amd64.tar.gz → extract → configure → run
```

---

## Step 1 — Create your GitHub repository

### Option A — via the GitHub website (easiest)

1. Go to **github.com → "+" → New repository**
2. Name it: `shanutechx-panel`
3. Set to **Private** while you're setting it up, change to Public later if you want
4. **Do not** initialise with a README, .gitignore, or license (you're importing existing code)
5. Click **Create repository** — you'll land on an empty repo page

### Option B — GitHub CLI (if you have `gh` installed)

```bash
gh repo create ShanudhaTirosh/shanutechx-panel --private --description "ShanuTechX VPN Panel"
```

---

## Step 2 — Prepare the source on your laptop or a VPS

You need Git, Node 20+, and Go 1.24+ installed locally **only if you want to test
the build locally** before pushing. If you trust GitHub Actions to build it, you
just need Git.

```bash
# 1. Unzip the original source
unzip 3x-ui-main.zip
mv 3x-ui-main shanutechx-panel
cd shanutechx-panel

# 2. Initialise git (it has no .git since you got it as a zip)
git init
git checkout -b main

# 3. Apply the brand patches from the shanutechx-patch.zip
#    (unzip it alongside the source folder)
unzip ../shanutechx-patch.zip -d /tmp/patch
cp -r /tmp/patch/shanutechx-patch/* .
#    This overwrites all the changed files AND adds:
#      .github/workflows/release.yml   ← the build workflow
#      shanutechx-install.sh           ← the installer

# 4. Add your GitHub remote
git remote add origin https://github.com/ShanudhaTirosh/shanutechx-panel.git
#    (or use SSH: git@github.com:ShanudhaTirosh/shanutechx-panel.git)

# 5. Commit everything
git add -A
git commit -m "chore: initial ShanuTechX branded fork of 3x-ui"
```

---

## Step 3 — Push and trigger your first build

```bash
# Push the main branch
git push -u origin main
```

This will trigger the workflow on the `main` branch push (builds all arches,
uploads as artifacts but does NOT create a public release yet).

Go to **github.com → ShanudhaTirosh/shanutechx-panel → Actions** and watch the
`Release ShanuTechX` workflow run. If it goes green, everything compiled correctly.

---

## Step 4 — Create your first release

A release is created when you push a **version tag**. The tag must match `v*.*.*`.

```bash
# Tag the current commit as v1.0.0
git tag v1.0.0

# Push the tag to GitHub → this triggers the release build
git push origin v1.0.0
```

GitHub Actions will now:
1. Build all four architectures in parallel (~10–15 min)
2. Create a GitHub Release named "ShanuTechX v1.0.0"
3. Attach `shanutechx-linux-amd64.tar.gz`, `shanutechx-linux-arm64.tar.gz`, etc.

You can see the release at:
`https://github.com/ShanudhaTirosh/shanutechx-panel/releases`

---

## Step 5 — Install on your VPS

Once the release is published, run your installer on a clean Ubuntu 22.04 VPS:

```bash
# Download and inspect before running (good practice)
curl -L https://raw.githubusercontent.com/ShanudhaTirosh/shanutechx-panel/main/shanutechx-install.sh \
  -o shanutechx-install.sh
less shanutechx-install.sh            # read it!

# Run it (no domain = HTTP-only, change password immediately)
sudo bash shanutechx-install.sh

# Or with a domain for automatic HTTPS via certbot
sudo bash shanutechx-install.sh -domain panel.yourdomain.com
```

**Flags you can pass:**

| Flag | Default | Description |
|---|---|---|
| `-domain panel.example.com` | IP-only | Enables HTTPS + certbot |
| `-port 2053` | `2053` | Internal panel port |
| `-user Shanu` | `Shanu` | Admin username |
| `-pass admin` | `admin` | ⚠ Change this! |
| `-build y` | off | Build from source instead of downloading release |
| `-version v1.0.0` | `latest` | Pin a specific release tag |

---

## Step 6 — Make changes and publish a new release

The workflow for updating the panel later:

```bash
# 1. Make your changes (new CSS, updated branding, etc.)
vim frontend/src/styles/page-shell.css

# 2. Commit
git add -A
git commit -m "feat: updated glassmorphism colours"

# 3. Push branch (builds and tests, no new release)
git push

# 4. When ready to release
git tag v1.0.1
git push origin v1.0.1
# → GitHub Actions builds and publishes v1.0.1 automatically
```

---

## What the Actions workflow does (summary)

The workflow at `.github/workflows/release.yml` runs on Ubuntu runners provided
free of charge by GitHub. It:

1. **Checks out** your repo source
2. **Builds the frontend** with `npm ci && npm run build` in `frontend/`
   — this produces `frontend/dist/` which Go embeds at compile time
3. **Downloads a Bootlin musl cross-toolchain** for each target architecture,
   which lets it produce fully static binaries (no glibc dependency on the VPS)
4. **Runs `go build`** with `-linkmode external -extldflags '-static'`
5. **Downloads Xray-core** for the matching arch plus geo-data files
6. **Packages** everything into `shanutechx-linux-<arch>.tar.gz`
7. **Uploads** the tarball to GitHub Artifacts (every build)
8. On a **tag push only**, creates a public GitHub Release and attaches the tarballs

---

## Troubleshooting common build failures

### "Toolchain not found for …"
Bootlin occasionally renames their toolchain directory. Click the failing Action,
expand `Build ShanuTechX binary`, and look at the `curl` output for the available
filename. Then open `.github/workflows/release.yml` and check the `BOOTLIN_ARCH`
mapping for that platform.

### "internal/web/dist: no such file or directory"
The Go backend embeds the built frontend. This error means the frontend build
step failed or ran after the Go build. In the workflow the `Build frontend` step
always runs before `Build ShanuTechX binary` — check the Node/npm step for errors.

### npm audit failure
Run `npm audit --fix` in `frontend/`, commit the lock file changes, and push again.

### Certbot fails on install
Your domain's DNS `A` record must resolve to your server's IP before certbot runs.
Check: `dig +short yourdomain.com` — it should return your VPS IP. The installer
still completes and leaves the panel accessible over HTTP so you can fix DNS and
re-run certbot manually: `certbot --nginx -d yourdomain.com`.

---

## Keeping up with upstream 3x-ui security patches

```bash
# Add the upstream remote once
git remote add upstream https://github.com/MHSanaei/3x-ui.git

# Fetch upstream changes
git fetch upstream

# Merge upstream main into your main (resolve conflicts in the brand files)
git merge upstream/main --no-ff -m "chore: merge upstream 3x-ui $(date +%Y-%m-%d)"

# The only files that will conflict are the ones you patched:
#   frontend/src/pages/login/LoginPage.tsx   ← keep <brand-name>ShanuTechX</brand-name>
#   frontend/src/layouts/AppSidebar.tsx      ← keep ShanuTechX / ShX brand strings
#   frontend/src/hooks/usePageTitle.ts       ← keep 'ShanuTechX' fallback
#   internal/database/db.go                  ← keep defaultUsername = "Shanu"
#   internal/web/service/setting.go          ← keep /ShanuTechX/ basepath default

# After resolving conflicts
git add -A
git commit -m "chore: resolve brand conflicts after upstream merge"
git tag v1.x.x
git push origin main --tags
```
