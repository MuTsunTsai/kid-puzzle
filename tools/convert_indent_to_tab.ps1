# Convert leading 2-space indent to tabs in *.dart files.
# Each leading pair of spaces becomes one tab. In-line whitespace and EOL chars
# (LF/CRLF) are preserved. YAML is intentionally not processed.
#
# Usage (run from project root):
#   pwsh ./tools/convert_indent_to_tab.ps1
#   pwsh ./tools/convert_indent_to_tab.ps1 -Paths lib
#   pwsh ./tools/convert_indent_to_tab.ps1 -DryRun

param(
	[string[]] $Paths = @("lib", "test"),
	[switch] $DryRun
)

$ErrorActionPreference = "Stop"
$TAB = [char] 9

function ConvertLine([string] $line) {
	$m = [regex]::Match($line, "^( {2})+")
	if (-not $m.Success) {
		return $line
	}
	$leading = $m.Value
	$tabCount = [int]($leading.Length / 2)
	return ($TAB.ToString() * $tabCount) + $line.Substring($leading.Length)
}

function ConvertFile([string] $path) {
	$content = [System.IO.File]::ReadAllText($path)
	$lines = $content -split "`n", -1
	$newLines = @()
	foreach ($line in $lines) {
		$newLines += ConvertLine $line
	}
	$newContent = $newLines -join "`n"
	return @{ original = $content; converted = $newContent }
}

$totalScanned = 0
$totalChanged = 0
$utf8NoBom = New-Object System.Text.UTF8Encoding $false

foreach ($p in $Paths) {
	if (-not (Test-Path $p)) {
		Write-Warning "Path not found, skipping: $p"
		continue
	}

	$files = Get-ChildItem -Path $p -Recurse -File -Filter "*.dart"
	foreach ($file in $files) {
		$totalScanned++
		$fp = $file.FullName
		$result = ConvertFile $fp
		if ($result.original -ne $result.converted) {
			$totalChanged++
			if ($DryRun) {
				Write-Output "[DRY] $fp"
			}
			else {
				[System.IO.File]::WriteAllText($fp, $result.converted, $utf8NoBom)
				Write-Output "Modified: $fp"
			}
		}
	}
}

Write-Output ""
Write-Output "Scanned $totalScanned file(s); $totalChanged file(s) modified."
if ($DryRun) { Write-Output "(DryRun mode - no files written)" }
