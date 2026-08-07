# Fork-sync workflow for `horse-provider-nghttp2` Horse.pas additions

**Goal**: land the seven `HORSE_PROVIDER_NGHTTP2` hooks in upstream `HashLoad/horse` via the `freitasjca/horse` fork.

**Split-of-labour**: the devcontainer's `horse/` bind mount is **read-only by design** — the source of truth for the patched Horse.pas lives at `patches/horse/src/Horse.pas`. From Windows you copy that file over `C:\lang\Repo\horse\src\Horse.pas` and drive the git workflow from Windows-side git tooling.

## Prerequisites — one-time setup

### 1. Horse fork remote layout

The Windows-side `C:\lang\Repo\horse` checkout already has both remotes wired:

```
origin    → git@github.com:freitasjca/horse.git   (your fork; push here)
upstream  → https://github.com/HashLoad/horse     (canonical; PR into here)
```

Verify from PowerShell / Git Bash on Windows:
```powershell
git -C C:\lang\Repo\horse remote -v
```

Or from the devcontainer (read-only mount is fine for reading):
```bash
git -C /workspaces/horse-crosssocket/horse remote -v
```

### 2. Fork-sync topology (**important — read `MEMORY.md` note**)

- Sync from **`upstream/master`** — the canonical branch
- **Never sync from `upstream/dev`** — it's stale (frozen at PR #458, 2026-05-20)
- Fork's working branch is `origin/dev`. Fork's `origin/master` mirrors upstream master
- The nghttp2 hooks go on a feature branch off `dev`, PR'd to upstream `master`

---

## Workflow

### Step A — regenerate `patches/horse/src/Horse.pas` if upstream drifted

Only needed if `HashLoad/horse` `master` has changed since the last snapshot in `patches/horse/src/Horse.pas`. Skip if the snapshot is fresh.

Staging lives at `.stage/horse-nghttp2/` under the workspace root — visible from WSL as `~/workspace/projects/horse-crosssocket/.stage/horse-nghttp2/` and from the VS Code file explorer inside the devcontainer. Survives container rebuilds. Ignored by git via the workspace-root `.gitignore`.

From the devcontainer:
```bash
STAGE=/workspaces/horse-crosssocket/.stage/horse-nghttp2

# Stage a fresh upstream copy
rm -rf "$STAGE" && mkdir -p "$STAGE/src"
cp /workspaces/horse-crosssocket/horse/src/Horse.pas "$STAGE/src/"

# Apply the 7 nghttp2 hooks to the fresh upstream
/workspaces/horse-crosssocket/patches/horse-provider-nghttp2/scripts/apply-horse-nghttp2-hooks.sh "$STAGE"

# Overwrite the snapshot in patches/
cp "$STAGE/src/Horse.pas" /workspaces/horse-crosssocket/patches/horse/src/Horse.pas

# Commit the refreshed snapshot to horse-crosssocket
cd /workspaces/horse-crosssocket
git add patches/horse/src/Horse.pas
git commit -m "chore(patches): refresh patched Horse.pas against upstream 3.3.x"

# Optional: inspect $STAGE/src/Horse.pas.pre-nghttp2-hooks.bak for the pre-apply
# backup, or delete the stage when you're done:
#   rm -rf "$STAGE"
```

**What the script does** (7 sections — spec in `patches/horse/src/HOOKS-FOR-NGHTTP2.md`):

| # | Where | What |
|---|---|---|
| 1 | Alias block | Add `HORSE_NGHTTP2` → `HORSE_PROVIDER_NGHTTP2` legacy alias |
| 2 | FATAL Rule 1 | Reject `HORSE_PROVIDER_NGHTTP2` × any `HORSE_HOST_*` |
| 3 | FATAL Rule 3 | Add `HORSE_PROVIDER_NGHTTP2` to `HORSE_NOPROVIDER` exclusivity OR chain |
| 4 | FATAL Rule 4 | Mutual exclusion with `CROSSSOCKET`/`MORMOT`/`ICS` + extend `HTTPSYS`/`EPOLL` chains |
| 5 | FPC `uses` | Add `Horse.Provider.Nghttp2` ELSEIF branch |
| 6 | Delphi `uses` | Add `Horse.Provider.Nghttp2` ELSEIF branch |
| 7 | Type-alias chain | Add `THorseProvider = Horse.Provider.Nghttp2.THorseProviderNghttp2` |

Idempotent — re-running is a no-op with a clear message.

### Step B — sync the fork's `dev` branch to upstream/master (from Windows)

Open PowerShell or Git Bash on Windows:
```powershell
cd C:\lang\Repo\horse
git fetch upstream
git checkout dev
git merge upstream/master        # resolve any conflicts, commit
git push origin dev
```

### Step C — copy the patched Horse.pas onto the feature branch (from Windows)

```powershell
cd C:\lang\Repo\horse
git checkout -b feat/provider-nghttp2-hooks dev

# Copy the snapshot from the horse-crosssocket workspace over the fork's Horse.pas
copy C:\lang\Repo\horse-crosssocket\patches\horse\src\Horse.pas C:\lang\Repo\horse\src\Horse.pas /Y

# Review — should show only the seven insertions vs upstream
git diff src/Horse.pas
```

### Step D — smoke-test the patched Horse against the provider

From Windows (Delphi IDE), open a project with:

```
Search path: 
  C:\lang\Repo\horse\src
  C:\lang\Repo\horse-provider-nghttp2\src
  
Compiler defines:
  HORSE_PROVIDER_NGHTTP2
```

The compile itself is the smoke test for the hooks — if `Horse.pas` compiles with the define set, the type-alias chain reaches `THorseProviderNghttp2` and every branch is wired correctly.

Task 6 (integration tests: `HorseNghttp2TestServer.dpr` / `HorseNghttp2TestClient.dpr`) will drive real HTTP/2 traffic through the built binary.

### Step E — commit and push to the fork (from Windows)

```powershell
cd C:\lang\Repo\horse
git add src/Horse.pas
git commit -m "feat(horse): add HORSE_PROVIDER_NGHTTP2 to axis-A provider chain

Wires the new nghttp2 transport provider into the PATCH-HORSE-2
three-axis define chain:

- Legacy alias HORSE_NGHTTP2 -> HORSE_PROVIDER_NGHTTP2
- FATAL guards: nghttp2 x HORSE_HOST_*, mutual exclusion with
  CROSSSOCKET/MORMOT/ICS, NOPROVIDER exclusivity
- uses-clause branches (FPC + Delphi)
- THorseProvider type-alias branch

Preserves G1-G8 backwards-compatibility contract. No existing
provider selection changes behaviour.

Companion PR: freitasjca/horse-provider-nghttp2 v0.1.
Specification: patches/horse/src/HOOKS-FOR-NGHTTP2.md"

git push -u origin feat/provider-nghttp2-hooks
```

### Step F — merge to fork's `dev` for internal use

While the upstream PR is under review, keep the hooks available in your fork's `dev` branch:

```powershell
git checkout dev
git merge feat/provider-nghttp2-hooks --ff-only    # or --no-ff for a merge commit
git push origin dev
```

### Step G — open the upstream PR

From Windows (or anywhere with the `gh` CLI configured):

```powershell
gh pr create `
  --repo HashLoad/horse `
  --base master `
  --head freitasjca:feat/provider-nghttp2-hooks `
  --title "Add HORSE_PROVIDER_NGHTTP2 to the axis-A provider chain" `
  --body-file C:\lang\Repo\horse-crosssocket\patches\horse\src\HOOKS-FOR-NGHTTP2.md
```

The hook doc doubles as the PR description — reviewers see the seven required insertions with exact line numbers and rationale, alongside the G1–G8 checklist.

### Step H — after upstream merge

Once the upstream PR is merged into `HashLoad/horse` `master`:

```powershell
cd C:\lang\Repo\horse
git fetch upstream
git checkout master
git merge upstream/master     # brings the merged hooks into your fork's master
git push origin master

git checkout dev
git merge upstream/master     # now dev has the upstream-blessed version
git push origin dev

# Delete the feature branch — the change is now upstream
git branch -d feat/provider-nghttp2-hooks
git push origin --delete feat/provider-nghttp2-hooks
```

Then, from the devcontainer, retire `patches/horse/src/Horse.pas`:
```bash
cd /workspaces/horse-crosssocket
mv patches/horse/src/Horse.pas patches/horse/src/Horse.pas.retired-upstream-YYYY-MM.bak
# update docs/patches-inventory.md: move Horse.pas out of active list back into retired list
```

At this point `apply-horse-nghttp2-hooks.sh` becomes a no-op on a fresh upstream Horse.pas — it detects `HORSE_PROVIDER_NGHTTP2` already present and exits early. Safe to leave in the repo as a fallback for anyone using an older Horse pin.

---

## Troubleshooting

**"Not upstream 3.3.0+ baseline"** — the script requires `PATCH-HORSE-2` markers in `Horse.pas`. If missing, either the fork is on an old branch or `dev` hasn't been synced from `upstream/master` recently. Run Step B first, then re-stage in Step A.

**"post-apply check failed"** — script auto-restores from `Horse.pas.pre-nghttp2-hooks.bak`. Usually means an anchor pattern didn't match (upstream renamed / restructured a section). Read `patches/horse/src/HOOKS-FOR-NGHTTP2.md` and apply the missed hook manually, then update the script's anchor for future runs.

**Merge conflicts on Step B** — someone else touched `Horse.pas` upstream. Resolve normally on Windows; then re-run Step A to regenerate the patched snapshot against the resolved baseline.

**"Read-only file system" when running the apply script against `horse/`** — expected. The `horse/` bind mount is deliberately read-only. Run the script against `.stage/horse-nghttp2/` under the workspace root (see Step A) so the writable target is a workspace-local scratch area, then copy the result into `patches/horse/src/`.
