# ===========================================================================
#  diagnose-dcc-cmdline.ps1
#  Companion to diagnose-dcc-cmdline.bat. Kept as a separate file rather than
#  an inline `powershell -Command "..."` because the analysis needs quotes,
#  braces and $_ throughout, and cmd's escaping of those inside a .bat is a
#  reliable source of silent corruption.
#
#  Answers one question: what fills the >32000-character DCC command line?
#
#  The distinction that matters is REPETITION versus LENGTH.
#    hundreds of identical -U entries  -> something is accumulating a property
#    one enormous unique list          -> a genuinely huge search path
#  Those have different fixes, and the "top repeated arguments" table below is
#  what separates them.
# ===========================================================================
param([Parameter(Mandatory=$true)][string]$LogPath)

if (-not (Test-Path $LogPath)) { Write-Host "No log at $LogPath"; exit 2 }

Write-Host ("log size: {0:N1} MB" -f ((Get-Item $LogPath).Length / 1MB))
Write-Host ""

# The DCC invocation is the longest line in a diagnostic log by a wide margin.
# Streamed rather than Get-Content'd whole: these logs reach hundreds of MB.
$longest = ''
$reader = [System.IO.File]::OpenText($LogPath)
try {
    while ($null -ne ($line = $reader.ReadLine())) {
        if ($line.Length -gt $longest.Length) { $longest = $line }
    }
} finally { $reader.Close() }

if ($longest.Length -eq 0) { Write-Host "log is empty"; exit 2 }

Write-Host "=== longest line: $($longest.Length) chars ==="
Write-Host ""
Write-Host "--- first 600 chars ---"
Write-Host $longest.Substring(0, [Math]::Min(600, $longest.Length))
Write-Host ""

$toks = $longest -split '\s+' | Where-Object { $_ -ne '' }
Write-Host "--- $($toks.Count) whitespace-separated arguments ---"
Write-Host ""

Write-Host "--- which switch dominates (by first 2 chars) ---"
$toks | Group-Object { if ($_.Length -ge 2) { $_.Substring(0,2) } else { $_ } } |
    Sort-Object Count -Descending | Select-Object -First 12 |
    ForEach-Object { "{0,8}  {1}" -f $_.Count, $_.Name } | Write-Host
Write-Host ""

# The decisive table. If the top entry has a count in the hundreds, something
# is appending the same value repeatedly and THAT is the bug - not the length
# of any individual path.
Write-Host "--- top repeated arguments (count > 1) ---"
$dupes = $toks | Group-Object | Where-Object { $_.Count -gt 1 } | Sort-Object Count -Descending
if ($dupes) {
    $dupes | Select-Object -First 15 | ForEach-Object {
        $v = $_.Name; if ($v.Length -gt 90) { $v = $v.Substring(0,90) + '...' }
        "{0,8}x  {1}" -f $_.Count, $v
    } | Write-Host
    $wasted = ($dupes | ForEach-Object { ($_.Count - 1) * ($_.Name.Length + 1) } | Measure-Object -Sum).Sum
    Write-Host ""
    Write-Host ("  duplicates account for {0} of {1} chars ({2:N0}%)" -f `
        $wasted, $longest.Length, (100.0 * $wasted / $longest.Length))
} else {
    Write-Host "  none - every argument is unique, so this is one genuinely huge list"
    Write-Host "  rather than something accumulating. Look at the longest arguments:"
    $toks | Sort-Object Length -Descending | Select-Object -First 5 |
        ForEach-Object { "{0,8}  {1}" -f $_.Length, $_ } | Write-Host
}
Write-Host ""
Write-Host "=== verdict ==="
if ($dupes -and $dupes[0].Count -ge 50) {
    Write-Host "  REPETITION. '$($dupes[0].Name.Substring(0,[Math]::Min(60,$dupes[0].Name.Length)))'"
    Write-Host "  appears $($dupes[0].Count) times. A property is accumulating - most likely a"
    Write-Host "  self-referencing `$(PROP) evaluated once per configuration section."
} elseif ($longest.Length -gt 32000) {
    Write-Host "  LENGTH, not repetition. The argument list is genuinely large."
    Write-Host "  Shortening paths or driving dcc64 directly are the options."
} else {
    Write-Host "  The longest line here is under 32000, so this log did not capture"
    Write-Host "  the failing invocation. Check the build actually reached DCC."
}
