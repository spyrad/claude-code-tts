# Builds the stand-alone install.ps1 from the sources in src/.
# Run after changing anything in src/:
#   powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1
param(
    [string]$OutFile = (Join-Path $PSScriptRoot 'install.ps1')
)

$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot 'src'
$template = [IO.File]::ReadAllText((Join-Path $src 'install-template.ps1'), [Text.Encoding]::UTF8)
$speak = [IO.File]::ReadAllText((Join-Path $src 'speak-last-answer.ps1'), [Text.Encoding]::UTF8).TrimEnd()
$edge = [IO.File]::ReadAllText((Join-Path $src 'edge_say.py'), [Text.Encoding]::UTF8).TrimEnd()

foreach ($embedded in $speak, $edge) {
    if ($embedded -match "(?m)^'@") { throw "Embedded script contains a line starting with '@ - it would end the here-string." }
}

$installer = $template.Replace('__SPEAK_SCRIPT__', $speak).Replace('__EDGE_SCRIPT__', $edge).Replace("`r`n", "`n")

# ASCII only: the one-liner (irm | scriptblock) must not depend on a BOM or code page
$nonAscii = [regex]::Matches($installer, '[^\x00-\x7F]')
if ($nonAscii.Count -gt 0) {
    $line = ($installer.Substring(0, $nonAscii[0].Index) -split "`n").Count
    throw "install.ps1 would contain $($nonAscii.Count) non-ASCII character(s), first on line $line."
}

$errors = $null
[void][Management.Automation.Language.Parser]::ParseInput($installer, [ref]$null, [ref]$errors)
if ($errors.Count -gt 0) { throw "install.ps1 does not parse: $($errors[0].Message) (line $($errors[0].Extent.StartLineNumber))" }

[IO.File]::WriteAllText($OutFile, $installer, (New-Object Text.UTF8Encoding($false)))
Write-Host "Built: $OutFile"
