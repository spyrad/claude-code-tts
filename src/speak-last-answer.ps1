# Claude Code Stop hook: reads Claude's last answer aloud (code blocks skipped).
# Online voice via edge-tts, automatic fallback to an offline Windows (SAPI) voice.
#
# Modes:
#   (default)  hook mode - reads the Stop hook JSON from stdin, speaks in the background
#   -Stop      silences a running speech (UserPromptSubmit hook and the stop hotkey)
#   -DryRun    hook mode, but prints the text instead of speaking (for testing)
#   -Worker    internal - speaks the given text file, then deletes it
#
# Voices: tts\voice.json next to the hooks folder (written by the installer), e.g.
#   { "engine": "edge", "edgeVoice": "en-US-AriaNeural", "edgeRate": "+0%",
#     "sapiVoice": "Microsoft Zira Desktop", "sapiRate": 1 }
# Off switch: create the file <claude dir>\tts-off (delete it to turn speech back on).
param(
    [switch]$Stop,
    [switch]$DryRun,
    [switch]$Worker,
    [string]$TextFile
)

$ClaudeDir  = Split-Path -Parent $PSScriptRoot   # this script lives in <claude dir>\hooks
$TtsDir     = Join-Path $ClaudeDir 'tts'

$Engine    = 'edge'                       # 'edge' (natural, online) or 'sapi' (offline only)
$EdgeVoice = 'en-US-AriaNeural'
$EdgeRate  = '+0%'                        # e.g. '+10%' faster, '-10%' slower
$VoiceName = 'Microsoft Zira Desktop'     # SAPI voice, also the fallback when edge fails
$Rate      = 1      # SAPI speed: -10 (slow) .. 10 (fast)
$MaxChars  = 3000   # safety cap for what gets spoken (~3 minutes)
$FirstChunkChars = 200   # small first chunk so speech starts quickly
$ChunkChars      = 450
$SynthTimeoutMs  = 10000

$configFile = Join-Path $TtsDir 'voice.json'
if (Test-Path $configFile) {
    try {
        $config = [IO.File]::ReadAllText($configFile) | ConvertFrom-Json
        if ($config.engine)    { $Engine    = $config.engine }
        if ($config.edgeVoice) { $EdgeVoice = $config.edgeVoice }
        if ($config.edgeRate)  { $EdgeRate  = $config.edgeRate }
        if ($config.sapiVoice) { $VoiceName = $config.sapiVoice }
        if ($null -ne $config.sapiRate) { $Rate = [int]$config.sapiRate }
    } catch { }
}

$StateDir   = Join-Path $env:TEMP 'claude-tts'
$PidFile    = Join-Path $StateDir 'speaker.pid'
$LogFile    = Join-Path $StateDir 'speak.log'
$OffFlag    = Join-Path $ClaudeDir 'tts-off'
$EdgeScript = Join-Path $TtsDir 'edge_say.py'

function Write-Log([string]$message) {
    Add-Content -Path $LogFile -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $message) -ErrorAction SilentlyContinue
}

function Stop-Speaker {
    if (-not (Test-Path $PidFile)) { return }
    $oldPid = Get-Content $PidFile -ErrorAction SilentlyContinue
    if ($oldPid) {
        Get-Process -Id $oldPid -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessName -eq 'powershell' } |
            Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $PidFile -ErrorAction SilentlyContinue
}

function Get-LastAnswer($payload) {
    if ($payload.last_assistant_message -is [string] -and $payload.last_assistant_message) {
        return $payload.last_assistant_message
    }
    $path = $payload.transcript_path
    if (-not $path -or -not (Test-Path $path)) { return $null }
    $lines = @(Get-Content $path -Tail 300 -Encoding UTF8)
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -notmatch '"type":"assistant"') { continue }
        try { $entry = $lines[$i] | ConvertFrom-Json } catch { continue }
        if ($entry.type -ne 'assistant') { continue }
        $texts = @($entry.message.content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text })
        if ($texts.Count -gt 0) { return ($texts -join "`n`n") }
    }
    return $null
}

function Add-Period([string]$s) {
    if ($s -match '[.!?:;,]$') { return $s }
    return "$s."
}

function Get-SpokenText([string]$markdown) {
    $t = $markdown -replace '(?s)```.*?```', "`n`n"
    # inline code: keep short identifiers, drop long paths/commands
    $t = [regex]::Replace($t, '`([^`]*)`', {
        param($m)
        if ($m.Groups[1].Value.Length -le 30) { $m.Groups[1].Value } else { '' }
    })
    $t = $t -replace '\[([^\]]+)\]\([^)]+\)', '$1'
    $t = $t -replace 'https?://\S+', ''

    $tableSeparator = '^\s*\|?[\s:|-]*-{3,}[\s:|-]*$'
    $picked = @()
    foreach ($paragraph in ($t -split '\r?\n\s*\r?\n')) {
        $lines = @($paragraph -split '\r?\n')
        $parts = @()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ($line -match '^\s*(-{3,}|\*{3,})\s*$' -or $line -match $tableSeparator) { continue }
            if ($line -match '^\s*\|') {
                # table: skip the header row, read each data row as one sentence
                if ($i + 1 -lt $lines.Count -and $lines[$i + 1] -match $tableSeparator) { continue }
                $cells = @($line.Trim().Trim('|') -split '\|' |
                    ForEach-Object { ($_ -replace '\*\*|__|\*', '').Trim() } | Where-Object { $_ })
                if ($cells.Count -gt 0) { $parts += Add-Period ($cells -join ', ') }
                continue
            }
            $isStructural = $line -match '^\s*(#{1,6}\s|([-*+]|\d+\.)\s)'
            $clean = $line -replace '^\s*#{1,6}\s*', '' -replace '^\s*>\s?', '' -replace '^\s*([-*+]|\d+\.)\s+', ''
            $clean = ($clean -replace '\*\*|__|\*', '' -replace '\s+', ' ').Trim()
            if (-not $clean) { continue }
            if ($isStructural) { $clean = Add-Period $clean }
            $parts += $clean
        }
        if ($parts.Count -eq 0) { continue }
        $picked += Add-Period ($parts -join ' ')
    }

    $text = ($picked -join ' ') -replace '\(\s*\)', '' -replace '(?<=[\w\)])\s+([.,;:!?])', '$1' -replace '\s{2,}', ' '
    $text = $text.Trim()
    if ($text.Length -gt $MaxChars) {
        $cut = $text.Substring(0, $MaxChars)
        $end = $cut.LastIndexOfAny([char[]]'.!?')
        if ($end -gt ($MaxChars / 3)) { $text = $cut.Substring(0, $end + 1) }
        else { $text = $cut.Substring(0, [Math]::Max($cut.LastIndexOf(' '), 1)) }
    }
    return $text
}

function Split-Chunks([string]$text) {
    $chunks = @()
    $current = ''
    foreach ($sentence in [regex]::Split($text, '(?<=[.!?:])\s+')) {
        $limit = if ($chunks.Count -eq 0) { $FirstChunkChars } else { $ChunkChars }
        if ($current -and ($current.Length + $sentence.Length + 1) -gt $limit) {
            $chunks += $current
            $current = $sentence
        } else {
            $current = ($current + ' ' + $sentence).Trim()
        }
    }
    if ($current) { $chunks += $current }
    return ,$chunks
}

function Invoke-Sapi([string]$text) {
    Add-Type -AssemblyName System.Speech
    $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
    try { $synth.SelectVoice($VoiceName) } catch {
        # preferred voice missing: use any installed voice in the language of the edge voice
        $culture = ($EdgeVoice -split '-')[0..1] -join '-'
        $sameLanguage = $synth.GetInstalledVoices() | Where-Object { $_.VoiceInfo.Culture.Name -eq $culture } | Select-Object -First 1
        if ($sameLanguage) { $synth.SelectVoice($sameLanguage.VoiceInfo.Name) }
    }
    $synth.Rate = $Rate
    $synth.Speak($text)
}

# Starts edge-tts for one chunk in the background; returns the process or $null.
function Start-EdgeSynth([string]$python, [string]$text, [string]$basePath) {
    [IO.File]::WriteAllText("$basePath.txt", $text, [Text.Encoding]::UTF8)
    try {
        return Start-Process $python -WindowStyle Hidden -PassThru -ArgumentList @(
            "`"$EdgeScript`"", "`"$basePath.txt`"", "`"$basePath.mp3`"", $EdgeVoice, $EdgeRate)
    } catch { return $null }
}

function Wait-EdgeSynth($process, [string]$basePath) {
    if (-not $process) { return $false }
    if (-not $process.WaitForExit($SynthTimeoutMs)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        return $false
    }
    $mp3 = Get-Item "$basePath.mp3" -ErrorAction SilentlyContinue
    return [bool]($mp3 -and $mp3.Length -gt 0)
}

function Invoke-Mp3([string]$path) {
    Add-Type -AssemblyName PresentationCore
    $player = New-Object System.Windows.Media.MediaPlayer
    $player.Open([Uri]$path)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while (-not $player.NaturalDuration.HasTimeSpan -and $clock.Elapsed.TotalSeconds -lt 5) { Start-Sleep -Milliseconds 50 }
    if (-not $player.NaturalDuration.HasTimeSpan) { $player.Close(); return $false }
    $length = $player.NaturalDuration.TimeSpan.TotalSeconds
    $player.Play()
    $clock.Restart()
    while ($player.Position.TotalSeconds -lt ($length - 0.05) -and $clock.Elapsed.TotalSeconds -lt ($length + 2)) {
        Start-Sleep -Milliseconds 100
    }
    $player.Close()
    return $true
}

# Plays chunk i while chunk i+1 is being synthesized; hands the rest to SAPI on any failure.
function Invoke-Edge([string]$text) {
    # the installer records the verified interpreter; otherwise use whatever is on PATH
    $pythonFile = Join-Path (Split-Path $EdgeScript) 'python-path.txt'
    $python = if (Test-Path $pythonFile) { (Get-Content $pythonFile -TotalCount 1).Trim() }
              else { (Get-Command python -ErrorAction SilentlyContinue).Source }
    if (-not $python -or -not (Test-Path $EdgeScript)) { return 'no python/edge_say.py' }
    $chunks = Split-Chunks $text
    $base = [IO.Path]::Combine($StateDir, 'chunk-' + [guid]::NewGuid().ToString('N'))
    $pending = Start-EdgeSynth $python $chunks[0] "$base-0"
    for ($i = 0; $i -lt $chunks.Count; $i++) {
        $ready = Wait-EdgeSynth $pending "$base-$i"
        if (-not $ready) {
            Invoke-Sapi (($chunks[$i..($chunks.Count - 1)]) -join ' ')
            return "fallback sapi at chunk $($i + 1)/$($chunks.Count)"
        }
        $pending = if ($i + 1 -lt $chunks.Count) { Start-EdgeSynth $python $chunks[$i + 1] "$base-$($i + 1)" } else { $null }
        $played = Invoke-Mp3 "$base-$i.mp3"
        Remove-Item "$base-$i.txt", "$base-$i.mp3" -ErrorAction SilentlyContinue
        if (-not $played) {
            Invoke-Sapi (($chunks[$i..($chunks.Count - 1)]) -join ' ')
            return "fallback sapi (playback) at chunk $($i + 1)/$($chunks.Count)"
        }
    }
    return "edge ok, $($chunks.Count) chunks"
}

if ($Worker) {
    $text = [IO.File]::ReadAllText($TextFile, [Text.Encoding]::UTF8)
    Remove-Item $TextFile -ErrorAction SilentlyContinue
    if ($Engine -eq 'edge') {
        $result = Invoke-Edge $text
        if ($result -like 'no *') { Invoke-Sapi $text; $result = "fallback sapi ($result)" }
    } else {
        Invoke-Sapi $text
        $result = 'sapi'
    }
    Write-Log "worker: $result"
    exit 0
}

if ($Stop) { Stop-Speaker; exit 0 }

try {
    if (Test-Path $OffFlag) { exit 0 }

    $reader = New-Object IO.StreamReader([Console]::OpenStandardInput(), [Text.Encoding]::UTF8)
    $raw = $reader.ReadToEnd()
    if (-not $raw) { exit 0 }
    $payload = $raw | ConvertFrom-Json

    $answer = Get-LastAnswer $payload
    if (-not $answer) { exit 0 }
    $spoken = Get-SpokenText $answer
    if (-not $spoken) { exit 0 }

    if ($DryRun) { Write-Output $spoken; exit 0 }

    New-Item -ItemType Directory -Force $StateDir | Out-Null
    $textPath = Join-Path $StateDir ('say-' + [guid]::NewGuid().ToString('N') + '.txt')
    [IO.File]::WriteAllText($textPath, $spoken, [Text.Encoding]::UTF8)

    Stop-Speaker
    $proc = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$PSCommandPath`"", '-Worker', '-TextFile', "`"$textPath`"")
    Set-Content -Path $PidFile -Value $proc.Id
    Write-Log "hook: $($spoken.Length) chars, engine $Engine"

    # leftovers from interrupted speeches
    Get-ChildItem $StateDir -Filter 'chunk-*' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-1) } |
        Remove-Item -ErrorAction SilentlyContinue
} catch {
    # never disturb Claude Code - speech is best effort
    if ($DryRun) { Write-Output "ERROR: $_" }
}
exit 0
