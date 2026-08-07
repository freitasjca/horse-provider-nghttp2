#!/usr/bin/env bash
# =============================================================================
#  apply-horse-nghttp2-hooks.sh
#  Applies the seven HORSE_PROVIDER_NGHTTP2 hooks documented in
#  patches/horse/src/HOOKS-FOR-NGHTTP2.md to a horse repo's src/Horse.pas.
#
#  Idempotent — safe to re-run. Bails out with a clear message if the target
#  isn't upstream 3.3.0+ baseline (missing PATCH-HORSE-2 markers).
#
#  Usage:
#    apply-horse-nghttp2-hooks.sh [<path-to-horse-repo>]
#      default: $HORSE_DIR env var, or /mnt/c/lang/Repo/horse
#
#  Requires: awk, grep, sed, mktemp. No external Pascal tooling.
# =============================================================================

set -euo pipefail

HORSE_DIR="${1:-${HORSE_DIR:-/mnt/c/lang/Repo/horse}}"
TARGET="$HORSE_DIR/src/Horse.pas"

# ── Precondition checks ────────────────────────────────────────────────────

if [[ ! -f "$TARGET" ]]; then
  echo "ERROR: Horse.pas not found at $TARGET" >&2
  echo "       Pass a horse checkout path as the first argument, or set HORSE_DIR." >&2
  exit 1
fi

if [[ ! -w "$TARGET" ]]; then
  echo "ERROR: $TARGET is not writable." >&2
  echo "       If you're in the devcontainer, ensure the horse/ bind mount in" >&2
  echo "       .devcontainer/devcontainer.json is not marked 'readonly'," >&2
  echo "       then rebuild the container (Ctrl+Shift+P → Dev Containers: Rebuild)." >&2
  exit 1
fi

if ! grep -q "PATCH-HORSE-2" "$TARGET"; then
  echo "ERROR: $TARGET lacks the PATCH-HORSE-2 markers." >&2
  echo "       Expected HashLoad/horse >= 3.3.0. Refusing to patch a version" >&2
  echo "       whose structure this script wasn't validated against." >&2
  exit 1
fi

if grep -q "HORSE_PROVIDER_NGHTTP2" "$TARGET"; then
  echo "Hooks already applied — Horse.pas mentions HORSE_PROVIDER_NGHTTP2. Nothing to do."
  exit 0
fi

BACKUP="$TARGET.pre-nghttp2-hooks.bak"
cp "$TARGET" "$BACKUP"
echo "→ backup written to $BACKUP"

# ── Line-ending normalisation ──────────────────────────────────────────────
# Windows-committed Horse.pas has CRLF endings. `$` anchors in sed/awk match
# before the \n, so they'd see \r as content and fail. Normalise to LF for the
# hook application, restore CRLF at the end if the original had it.
HAD_CRLF=0
if head -1 "$BACKUP" | grep -q $'\r'; then
  HAD_CRLF=1
  sed -i 's/\r$//' "$TARGET"
fi

# ── Hook 1 — legacy alias  (append after HORSE_FCGI alias) ─────────────────

sed -i '/^{$IFDEF HORSE_FCGI}[[:space:]]*{$DEFINE HORSE_HOST_FCGI}/a\
{$IFDEF HORSE_NGHTTP2}     {$DEFINE HORSE_PROVIDER_NGHTTP2}     {$ENDIF}' "$TARGET"

# ── Hook 2 — FATAL Rule 1  (self-hosted × host-managed for NGHTTP2) ────────
# Insert before the "Rule 2" section comment.
awk '
/^\{ Rule 2 .* cross-platform Application-type mismatch \}/ && !inserted {
  print "{$IF DEFINED(HORSE_PROVIDER_NGHTTP2)}"
  print "  {$IF DEFINED(HORSE_HOST_ISAPI)}"
  print "    {$MESSAGE FATAL '\''HORSE_PROVIDER_NGHTTP2 cannot combine with HORSE_HOST_ISAPI — IIS owns the socket; a self-hosted Provider cannot coexist.'\''}"
  print "  {$ENDIF}"
  print "  {$IF DEFINED(HORSE_HOST_APACHE)}"
  print "    {$MESSAGE FATAL '\''HORSE_PROVIDER_NGHTTP2 cannot combine with HORSE_HOST_APACHE — Apache owns the socket; a self-hosted Provider cannot coexist.'\''}"
  print "  {$ENDIF}"
  print "  {$IF DEFINED(HORSE_HOST_CGI)}"
  print "    {$MESSAGE FATAL '\''HORSE_PROVIDER_NGHTTP2 cannot combine with HORSE_HOST_CGI — the web server owns the socket; a self-hosted Provider cannot coexist.'\''}"
  print "  {$ENDIF}"
  print "  {$IF DEFINED(HORSE_HOST_FCGI)}"
  print "    {$MESSAGE FATAL '\''HORSE_PROVIDER_NGHTTP2 cannot combine with HORSE_HOST_FCGI — FastCGI talks to a web server; a self-hosted Provider cannot coexist.'\''}"
  print "  {$ENDIF}"
  print "{$IFEND}"
  print ""
  inserted = 1
}
{ print }
' "$TARGET" > "$TARGET.tmp" && mv "$TARGET.tmp" "$TARGET"

# ── Hook 3 — Rule 3 NOPROVIDER exclusivity  (extend OR chain) ──────────────
# Line 199 has the big OR chain; add HORSE_PROVIDER_NGHTTP2 after ICS.
sed -i 's|DEFINED(HORSE_PROVIDER_ICS) or DEFINED(HORSE_APPTYPE_VCL)|DEFINED(HORSE_PROVIDER_ICS) or DEFINED(HORSE_PROVIDER_NGHTTP2) or DEFINED(HORSE_APPTYPE_VCL)|' "$TARGET"

# ── Hook 4a — mutual exclusion  (add 3 new IFEND blocks) ───────────────────
# Insert before the HTTPSYS mutual-exclusion pair.
awk '
/^\{\$IF DEFINED\(HORSE_PROVIDER_HTTPSYS\) and \(DEFINED\(HORSE_PROVIDER_CROSSSOCKET\)/ && !inserted {
  print "{$IF DEFINED(HORSE_PROVIDER_NGHTTP2) and DEFINED(HORSE_PROVIDER_CROSSSOCKET)}"
  print "  {$MESSAGE FATAL '\''HORSE_PROVIDER_NGHTTP2 and HORSE_PROVIDER_CROSSSOCKET are mutually exclusive — pick exactly one transport Provider per build.'\''}"
  print "{$IFEND}"
  print "{$IF DEFINED(HORSE_PROVIDER_NGHTTP2) and DEFINED(HORSE_PROVIDER_MORMOT)}"
  print "  {$MESSAGE FATAL '\''HORSE_PROVIDER_NGHTTP2 and HORSE_PROVIDER_MORMOT are mutually exclusive — pick exactly one transport Provider per build.'\''}"
  print "{$IFEND}"
  print "{$IF DEFINED(HORSE_PROVIDER_NGHTTP2) and DEFINED(HORSE_PROVIDER_ICS)}"
  print "  {$MESSAGE FATAL '\''HORSE_PROVIDER_NGHTTP2 and HORSE_PROVIDER_ICS are mutually exclusive — pick exactly one transport Provider per build.'\''}"
  print "{$IFEND}"
  inserted = 1
}
{ print }
' "$TARGET" > "$TARGET.tmp" && mv "$TARGET.tmp" "$TARGET"

# ── Hook 4b — extend HTTPSYS/EPOLL/IOCP OR chains with NGHTTP2 ─────────────
sed -i \
  -e 's|HORSE_PROVIDER_HTTPSYS) and (DEFINED(HORSE_PROVIDER_CROSSSOCKET) or DEFINED(HORSE_PROVIDER_MORMOT))|HORSE_PROVIDER_HTTPSYS) and (DEFINED(HORSE_PROVIDER_CROSSSOCKET) or DEFINED(HORSE_PROVIDER_MORMOT) or DEFINED(HORSE_PROVIDER_NGHTTP2))|' \
  -e 's|HORSE_PROVIDER_EPOLL) and (DEFINED(HORSE_PROVIDER_CROSSSOCKET) or DEFINED(HORSE_PROVIDER_MORMOT) or DEFINED(HORSE_PROVIDER_HTTPSYS))|HORSE_PROVIDER_EPOLL) and (DEFINED(HORSE_PROVIDER_CROSSSOCKET) or DEFINED(HORSE_PROVIDER_MORMOT) or DEFINED(HORSE_PROVIDER_HTTPSYS) or DEFINED(HORSE_PROVIDER_NGHTTP2))|' \
  "$TARGET"

# ── Hook 5 — FPC uses branch  (add NGHTTP2 ELSEIF) ─────────────────────────
# Uses awk with a state flag: enter "in FPC block" at {$IF DEFINED(FPC)},
# exit at the first {$ELSEIF DEFINED(HORSE_NOPROVIDER)} which closes the FPC
# block. Insert the new branch before the FPC-block "APPTYPE_DAEMON" fallback.
awk '
BEGIN { infpc = 0; inserted = 0 }
/^\{\$IF DEFINED\(FPC\)\}$/                              { infpc = 1 }
/^\{\$ELSEIF DEFINED\(HORSE_NOPROVIDER\)\}$/             { infpc = 0 }
infpc && /^  \{\$ELSEIF DEFINED\(HORSE_APPTYPE_DAEMON\)\}$/ && !inserted {
  print "  {$ELSEIF DEFINED(HORSE_PROVIDER_NGHTTP2)}"
  print "  Horse.Provider.Nghttp2,   { Console-shape — nghttp2 has no cross-product units in v1 }"
  inserted = 1
}
{ print }
' "$TARGET" > "$TARGET.tmp" && mv "$TARGET.tmp" "$TARGET"

# ── Hook 6 — Delphi uses branch  (add NGHTTP2 ELSEIF after ICS) ────────────
# Anchor: the Delphi HORSE_PROVIDER_ICS "Horse.Provider.ICS," entry followed
# by the trailing {$ENDIF}. Insert new NGHTTP2 branch after that {$ENDIF}.
awk '
BEGIN { seen_ics = 0; inserted = 0 }
/^  Horse.Provider.ICS,[[:space:]]*\{ Console-shape/ { seen_ics = 1 }
seen_ics && !inserted && /^  \{\$ENDIF\}$/ {
  print
  print "{$ELSEIF DEFINED(HORSE_PROVIDER_NGHTTP2)}"
  print "  System.SysUtils,"
  print "  Horse.Provider.Nghttp2,"
  inserted = 1
  next
}
{ print }
' "$TARGET" > "$TARGET.tmp" && mv "$TARGET.tmp" "$TARGET"

# ── Hook 7 — Type-alias chain  (add NGHTTP2 branch after ICS) ──────────────
# Anchor: the ICS type-alias block ending {$ENDIF} inside the type-alias chain
# (distinct from the earlier uses-clause {$ENDIF}). Match on the ICS console
# line specifically:  THorseProvider = Horse.Provider.ICS.THorseProviderICS;
awk '
BEGIN { seen_ics = 0; inserted = 0 }
/^    THorseProvider = Horse.Provider.ICS.THorseProviderICS;$/ { seen_ics = 1 }
seen_ics && !inserted && /^  \{\$ENDIF\}$/ {
  print
  print "{$ELSEIF DEFINED(HORSE_PROVIDER_NGHTTP2)}"
  print "  THorseProvider = Horse.Provider.Nghttp2.THorseProviderNghttp2;"
  inserted = 1
  next
}
{ print }
' "$TARGET" > "$TARGET.tmp" && mv "$TARGET.tmp" "$TARGET"

# ── Post-conditions ───────────────────────────────────────────────────────

MENTIONS=$(grep -c 'HORSE_PROVIDER_NGHTTP2' "$TARGET" || true)
# Expect ≥14 mentions across the seven hooks:
#   hook 1: 1  hook 2: 5  hook 3: 1  hook 4a: 3  hook 4b: 2  hook 5: 1  hook 6: 1  hook 7: 1
if [[ "$MENTIONS" -lt 14 ]]; then
  echo "ERROR: post-apply check failed — expected ≥14 mentions of HORSE_PROVIDER_NGHTTP2, found $MENTIONS." >&2
  echo "       Not every hook fired. Restoring backup." >&2
  mv "$BACKUP" "$TARGET"
  exit 1
fi

# Verify each of the seven expected sentinels landed
for sentinel in \
  'HORSE_NGHTTP2}     {$DEFINE HORSE_PROVIDER_NGHTTP2}' \
  'HORSE_PROVIDER_NGHTTP2 cannot combine with HORSE_HOST_ISAPI' \
  'HORSE_PROVIDER_NGHTTP2) or DEFINED(HORSE_APPTYPE_VCL)' \
  'HORSE_PROVIDER_NGHTTP2 and HORSE_PROVIDER_CROSSSOCKET are mutually exclusive' \
  'Horse.Provider.Nghttp2,   { Console-shape' \
  'THorseProvider = Horse.Provider.Nghttp2.THorseProviderNghttp2'; do
  if ! grep -qF "$sentinel" "$TARGET"; then
    echo "ERROR: post-apply sentinel missing: $sentinel" >&2
    echo "       Restoring backup." >&2
    mv "$BACKUP" "$TARGET"
    exit 1
  fi
done

# ── Restore CRLF if original had it ────────────────────────────────────────
if [[ "$HAD_CRLF" == "1" ]]; then
  sed -i 's/$/\r/' "$TARGET"
fi

echo "✓ applied — $MENTIONS references to HORSE_PROVIDER_NGHTTP2 now in $TARGET"
echo "  backup at $BACKUP (delete once you're happy)"
echo
echo "Diff summary vs backup:"
diff -u "$BACKUP" "$TARGET" | head -80 || true
echo
echo "Next steps:"
echo "  cd $HORSE_DIR"
echo "  git checkout -b feat/provider-nghttp2-hooks   # or use existing dev"
echo "  git diff src/Horse.pas                        # review"
echo "  git add src/Horse.pas"
echo "  git commit -m 'feat(horse): add HORSE_PROVIDER_NGHTTP2 hooks'"
echo "  git push origin feat/provider-nghttp2-hooks"
echo "  gh pr create --repo HashLoad/horse --base master --head freitasjca:feat/provider-nghttp2-hooks"
echo
echo "See patches/horse-provider-nghttp2/scripts/fork-sync-workflow.md for the full runbook."
