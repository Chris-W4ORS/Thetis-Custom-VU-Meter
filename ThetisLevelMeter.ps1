#Requires -Version 7.0
<#
.SYNOPSIS
    Thetis Level Meter - W4ORS / HAL1
    Live dual VU-style meter: RX audio from Thetis (via TCI) and TX mic audio
    from Voicemeeter Out B1 (via WASAPI) — the same final chain output the
    recorder captures. Monitoring only — nothing is recorded or encoded. Use
    this to dial in gain staging in Voicemeeter / Thetis / NVIDIA Broadcast
    before running ThetisQSORecorder.

.DESCRIPTION
    RX source: TCI audio_start:0 binary frames (float32, same stream the
               recorder uses) — shows whatever the receiver is producing,
               continuously, regardless of MOX state.
    TX source: WASAPI capture on Voicemeeter Out B1 — the final output of
               FDUCE mic → NVIDIA Broadcast (noise suppression) → Voicemeeter
               A1 (EQ/Compressor) → B1, i.e. exactly what feeds Thetis. Shows
               mic input continuously.
    Target zone on both meters: -22 to -20 dBFS average, don't cross -6 dBFS
    on peaks. Same targets the recorder's Leveler/Compressor/Limiter expect.

.NOTES
    Requires: PowerShell 7+, internet access on first run (NAudio bootstrap
    — same lib folder the recorder uses, so no second download if you've
    already run ThetisQSORecorder_Balancer.ps1 once).
    First run walks you through picking your mic/TX capture device and
    confirming the TCI host/port, then remembers it in
    %APPDATA%\ThetisQSORecorder\config.json. Run with -Reconfigure to redo
    that setup (e.g. after changing audio devices or moving to a new PC).
#>

param(
    [switch]$Reconfigure   # re-run the first-time device/TCI setup wizard even if a saved config exists
)

# ─────────────────────────────────────────────────────────────────────────────
# USER CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────
$TciHost        = "auto"        # "auto" = discover TCI bind address automatically
$TciPort        = 50001
$TciTrxIndex    = 0
$SampleRate     = 48000
$Channels       = 2             # RX TCI stream is stereo per Thetis's default

$TxDeviceSubstr = "Voicemeeter Out B1"   # partial match, case-insensitive

# Meter scale and target zone (dBFS) — shared by both meters
$MeterFloorDb   = -60.0
$MeterCeilDb    = 0.0
$TargetLowDb    = -22.0   # shifted down from -20 to match the recorder's
$TargetHighDb   = -20.0   # LevelerTargetDb move from -18 to -20dB
$HotDb          = -6.0          # above this = yellow "getting hot" zone
$ClipDb         = -1.0          # above this = red clip warning, latches briefly

# Smoothing
$RmsWindowSeconds  = 0.3        # RMS meter ballistics (fast-ish, like a VU meter)
$PeakDecayDbPerSec = 14.0       # how fast the peak-hold marker falls
$ClipLatchMs       = 1500       # how long the clip warning stays lit

$LibDir = "$env:APPDATA\ThetisQSORecorder\lib"   # shared with the recorder script
$NAudioCoreVersion   = "2.2.1"
$NAudioWasapiVersion = "2.2.1"

# Diagnostic logging — one file per day, kept next to the shared lib folder.
# RxFrameGapWarnMs: how long the RX (TCI) side can go without a new binary
# audio frame before we log it as a gap — this is the main thing we're trying
# to catch (the meter appearing to "lose" RX audio the recorder still has).
$LogDir            = "$env:APPDATA\ThetisQSORecorder\logs"
$RxFrameGapWarnMs   = 150
$UiStallWarnMs      = 100   # tick interval is 40ms; flag anything meaningfully later than that

# Saved setup (device choice + TCI host/port) — same parent folder as the
# recorder's lib/log folders, so everything for this toolkit lives in one
# place under the current Windows user's profile.
$ConfigDir  = "$env:APPDATA\ThetisQSORecorder"
$ConfigFile = Join-Path $ConfigDir "LevelMeter.config.json"
# ─────────────────────────────────────────────────────────────────────────────

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Diagnostic log ────────────────────────────────────────────────────────────
# Plain timestamped text log, one line per event. Kept deliberately terse
# (not a full trace) so it's still readable after a multi-hour QSO session.
# Flushed on every write since this process can be killed abruptly.
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$script:LogFile = Join-Path $LogDir ("LevelMeter_{0}.log" -f (Get-Date -Format "yyyyMMdd"))
$LogRetentionDays = 5

function Write-MeterLog {
    param([string]$Level, [string]$Msg)
    $line = "{0:yyyy-MM-dd HH:mm:ss.fff} [{1}] {2}" -f (Get-Date), $Level, $Msg
    try { Add-Content -Path $script:LogFile -Value $line -Encoding utf8 } catch {}
}

# Prune log files older than the retention window. Cheap and only runs once
# at startup, so no need to throttle it — filenames are date-stamped
# (LevelMeter_yyyyMMdd.log) so this is just a LastWriteTime check.
try {
    $cutoff = (Get-Date).AddDays(-$LogRetentionDays)
    Get-ChildItem -Path $LogDir -Filter "LevelMeter_*.log" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue
} catch {}

Write-MeterLog "INFO" "=== ThetisLevelMeter starting ==="

# ── NAudio bootstrap (Core + Wasapi only — no Lame needed, nothing is encoded) ─
function Expand-NuGet {
    param([string]$PackageId, [string]$Version, [string]$DestDir)
    $nupkg = "$DestDir\$PackageId.nupkg"
    $url   = "https://www.nuget.org/api/v2/package/$PackageId/$Version"
    Write-Host "  Downloading $PackageId $Version..." -ForegroundColor Yellow
    Invoke-WebRequest -Uri $url -OutFile $nupkg -UseBasicParsing
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($nupkg)
    foreach ($entry in $zip.Entries) {
        if ($entry.FullName -match "lib/(net472|net48|netstandard2\.0)/.*\.dll$") {
            $dest = Join-Path $DestDir ([System.IO.Path]::GetFileName($entry.FullName))
            if (-not (Test-Path $dest)) {
                $s = $entry.Open(); $f = [System.IO.File]::Create($dest)
                $s.CopyTo($f); $f.Close(); $s.Close()
            }
        }
    }
    $zip.Dispose()
    Remove-Item $nupkg -Force
}

function Install-Dependencies {
    New-Item -ItemType Directory -Force -Path $LibDir | Out-Null
    $hasCore   = Test-Path "$LibDir\NAudio.Core.dll"
    $hasWasapi = Test-Path "$LibDir\NAudio.Wasapi.dll"
    Get-ChildItem -Path $LibDir -Filter "*.nupkg" -ErrorAction SilentlyContinue | Remove-Item -Force
    if ($hasCore -and $hasWasapi) {
        Write-Host "[Libs] Dependencies already installed." -ForegroundColor Green
        return
    }
    Write-Host "[Libs] Bootstrapping dependencies from NuGet..." -ForegroundColor Yellow
    if (-not $hasCore)   { Expand-NuGet "NAudio.Core"   $NAudioCoreVersion   $LibDir }
    if (-not $hasWasapi) { Expand-NuGet "NAudio.Wasapi" $NAudioWasapiVersion $LibDir }
    Write-Host "[Libs] Bootstrap complete." -ForegroundColor Green
}
Install-Dependencies

foreach ($dll in @("NAudio.Core.dll","NAudio.Wasapi.dll")) {
    try { Add-Type -Path (Join-Path $LibDir $dll) } catch {}
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ── Level math (RMS EMA + instantaneous peak) — shared C# helper ─────────────
Add-Type -TypeDefinition @"
namespace ThetisMeter {
    public static class LevelCalc {
        // floatBytes: interleaved 32-bit float PCM. Returns rmsDb via ref emaMeanSq
        // (caller keeps state between calls) and instantaneous peakDb for this buffer.
        public static void ProcessFloat(byte[] floatBytes, int byteCount,
                                         ref double emaMeanSq, double windowCoeff,
                                         out double rmsDb, out double peakDb) {
            int n = byteCount / 4;
            double peak = 0.0;
            // windowCoeff is a PER-SAMPLE decay rate (very close to 1, since
            // it's meant to be applied once per sample at 48kHz) — so the
            // update has to happen inside this loop, once per sample, not
            // once for the whole buffer using a bulk average. Doing it once
            // per buffer call was the actual bug: with windowCoeff this
            // close to 1, a single per-call update only lets in a tiny
            // fraction of new information each time, so the RMS reading
            // barely moved even across many seconds of real audio.
            double ema = emaMeanSq;
            for (int i = 0; i < n; i++) {
                float v = System.BitConverter.ToSingle(floatBytes, i * 4);
                double d = v;
                double sq = d * d;
                ema = windowCoeff * ema + (1.0 - windowCoeff) * sq;
                double av = System.Math.Abs(d);
                if (av > peak) peak = av;
            }
            emaMeanSq = ema;
            rmsDb  = emaMeanSq > 1e-10 ? 10.0 * System.Math.Log10(emaMeanSq) : -120.0;
            peakDb = peak > 1e-6 ? 20.0 * System.Math.Log10(peak) : -120.0;
        }

        // int16Bytes: interleaved 16-bit PCM.
        public static void ProcessInt16(byte[] pcmBytes, int byteCount,
                                         ref double emaMeanSq, double windowCoeff,
                                         out double rmsDb, out double peakDb) {
            int n = byteCount / 2;
            double peak = 0.0;
            double ema = emaMeanSq;
            for (int i = 0; i < n; i++) {
                short s = (short)(pcmBytes[i * 2] | (pcmBytes[i * 2 + 1] << 8));
                double d = s / 32768.0;
                double sq = d * d;
                ema = windowCoeff * ema + (1.0 - windowCoeff) * sq;
                double av = System.Math.Abs(d);
                if (av > peak) peak = av;
            }
            emaMeanSq = ema;
            rmsDb  = emaMeanSq > 1e-10 ? 10.0 * System.Math.Log10(emaMeanSq) : -120.0;
            peakDb = peak > 1e-6 ? 20.0 * System.Math.Log10(peak) : -120.0;
        }
    }
}
"@

$rmsWindowCoeff = [System.Math]::Exp(-1.0 / ($SampleRate * $RmsWindowSeconds))

# Shared live state, read by the UI timer, written by capture callbacks
$script:rxEmaMeanSq  = [System.Math]::Pow(10.0, -40.0 / 10.0)
$script:txEmaMeanSq  = [System.Math]::Pow(10.0, -40.0 / 10.0)
$script:rxRmsDb      = -120.0
$script:txRmsDb      = -120.0
$script:rxPeakHoldDb = -120.0
$script:txPeakHoldDb = -120.0
$script:rxClipUntil  = [DateTime]::MinValue
$script:txClipUntil  = [DateTime]::MinValue
$script:rxConnected  = $false
$script:txConnected  = $false
$script:closing      = $false

# Rolling history for the windowed readouts (3s max peak, 10s average level).
# Each entry is a [PSCustomObject]@{ T = <DateTime>; Peak = <double>; RmsLinPow = <double> }
# — RmsLinPow is linear power (10^(rmsDb/10)) so the 10s average is a true
# power-domain average, not an average of dB values (which would be wrong).
$script:rxHistory = [System.Collections.Generic.List[object]]::new()
$script:txHistory = [System.Collections.Generic.List[object]]::new()
$Peak3sWindowSec  = 3.0
$Avg10sWindowSec  = 10.0
$MaxHistoryAgeSec = 10.0   # prune anything older than the longest window in use

function Add-History {
    param([string]$Source, [double]$PeakDb, [double]$RmsDb, [double]$MaxAgeSec = 10.0)
    $entry = [PSCustomObject]@{
        T         = Get-Date
        Peak      = $PeakDb
        RmsLinPow = [System.Math]::Pow(10.0, $RmsDb / 10.0)
    }
    # Defensive: re-create the list on the fly if it's ever null, rather than
    # crash. (Guards against any scoping edge case that could null this out
    # between script init and the timer tick that calls this.)
    if ($Source -eq "rx") {
        if ($null -eq $script:rxHistory) { $script:rxHistory = [System.Collections.Generic.List[object]]::new() }
        $list = $script:rxHistory
    } else {
        if ($null -eq $script:txHistory) { $script:txHistory = [System.Collections.Generic.List[object]]::new() }
        $list = $script:txHistory
    }
    $list.Add($entry)
    # Prune old entries (cheap: only ever trims from the front, list stays short)
    # NOTE: $MaxAgeSec is a real parameter (not an ambient script-scope lookup)
    # on purpose — reading $MaxHistoryAgeSec directly from this function's body
    # was unreliable at this call depth (Tick -> Pump-TciReceive ->
    # Update-PeakHold -> Add-History) and was silently resolving to 0/null,
    # which set the prune cutoff to "right now" and wiped the list down to
    # ~1 entry on every single call — exactly why the 10s average was
    # tracking the instantaneous RMS instead of a real trailing window.
    $cutoff = (Get-Date).AddSeconds(-$MaxAgeSec)
    while ($list.Count -gt 0 -and $list[0].T -lt $cutoff) { $list.RemoveAt(0) }
}

function Get-WindowedStats {
    param([string]$Source, [double]$PeakWindowSec, [double]$AvgWindowSec)
    if ($Source -eq "rx") {
        if ($null -eq $script:rxHistory) { $script:rxHistory = [System.Collections.Generic.List[object]]::new() }
        $list = $script:rxHistory
    } else {
        if ($null -eq $script:txHistory) { $script:txHistory = [System.Collections.Generic.List[object]]::new() }
        $list = $script:txHistory
    }
    $now = Get-Date
    $peakCutoff = $now.AddSeconds(-$PeakWindowSec)
    $avgCutoff  = $now.AddSeconds(-$AvgWindowSec)

    $peak3 = -120.0
    $sumPow = 0.0
    $countAvg = 0
    foreach ($e in $list) {
        if ($e.T -ge $peakCutoff -and $e.Peak -gt $peak3) { $peak3 = $e.Peak }
        if ($e.T -ge $avgCutoff) { $sumPow += $e.RmsLinPow; $countAvg++ }
    }
    $avgDb = if ($countAvg -gt 0) { 10.0 * [System.Math]::Log10($sumPow / $countAvg) } else { -120.0 }
    return @{ Peak3s = $peak3; Avg10s = $avgDb }
}

function Update-PeakHold {
    param([string]$Source, [double]$InstantPeakDb, [double]$DecayDbPerCall)
    if ($Source -eq "rx") {
        if ($InstantPeakDb -gt $script:rxPeakHoldDb) { $script:rxPeakHoldDb = $InstantPeakDb }
        if ($InstantPeakDb -ge $ClipDb) { $script:rxClipUntil = (Get-Date).AddMilliseconds($ClipLatchMs) }
    } else {
        if ($InstantPeakDb -gt $script:txPeakHoldDb) { $script:txPeakHoldDb = $InstantPeakDb }
        if ($InstantPeakDb -ge $ClipDb) { $script:txClipUntil = (Get-Date).AddMilliseconds($ClipLatchMs) }
    }
    Add-History -Source $Source -PeakDb $InstantPeakDb -RmsDb $(if ($Source -eq "rx") { $script:rxRmsDb } else { $script:txRmsDb })
}

# ── First-run setup wizard ─────────────────────────────────────────────────────
# Lets this script be handed to someone else (different PC, different audio
# devices) without them having to open and edit the source. On first launch —
# or any time you run with -Reconfigure — this walks through picking the
# capture device and confirming the TCI host/port, then remembers the answer
# in $ConfigFile so every future launch is silent. Note: Get-TciCandidateHosts
# and Test-TciPort are defined further down in this file, but PowerShell
# resolves all top-level function definitions in a script before executing
# any of its statements, so calling them here (textually earlier) is fine.
function Invoke-SetupWizard {
    Write-Host ""
    Write-Host "=== Thetis Level Meter -- first-time setup ===" -ForegroundColor Cyan
    Write-Host "(Run this script with -Reconfigure any time to redo this.)" -ForegroundColor DarkGray
    Write-Host ""

    $enum = [NAudio.CoreAudioApi.MMDeviceEnumerator]::new()
    $devs = @($enum.EnumerateAudioEndPoints([NAudio.CoreAudioApi.DataFlow]::Capture, [NAudio.CoreAudioApi.DeviceState]::Active))
    if ($devs.Count -eq 0) {
        Write-Warning "No active recording devices were found on this PC. Setup can't continue -- check Windows Sound settings and re-run."
        Write-MeterLog "ERROR" "Setup wizard: no active capture devices found"
        return $null
    }

    Write-Host "Which device carries your mic audio into Thetis? (this is what the TX meter watches)"
    for ($i = 0; $i -lt $devs.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $devs[$i].FriendlyName)
    }
    $choice = $null
    while ($null -eq $choice) {
        $raw = Read-Host "Enter a number"
        if ($raw -match '^\d+$' -and [int]$raw -ge 1 -and [int]$raw -le $devs.Count) { $choice = [int]$raw - 1 }
        else { Write-Host "  Enter a number between 1 and $($devs.Count)." -ForegroundColor Yellow }
    }
    $chosenDevice = $devs[$choice]
    Write-Host "Using: $($chosenDevice.FriendlyName)" -ForegroundColor Green
    Write-Host ""

    $hostIn = Read-Host "Thetis TCI host -- press Enter to auto-detect, or type an IP (e.g. 127.0.0.1)"
    $tciHostVal = if ([string]::IsNullOrWhiteSpace($hostIn)) { "auto" } else { $hostIn.Trim() }

    $portIn = Read-Host "Thetis TCI port [50001]"
    $tciPortVal = if ([string]::IsNullOrWhiteSpace($portIn)) { 50001 } elseif ($portIn -match '^\d+$') { [int]$portIn } else {
        Write-Host "  Not a valid port number, using default 50001." -ForegroundColor Yellow
        50001
    }

    # Live-test right now, using the values just entered, so a typo or a
    # "TCI Server" that isn't enabled yet in Thetis gets caught during setup
    # instead of silently on every future launch.
    Write-Host ""
    Write-Host "Testing TCI connection..." -ForegroundColor Cyan
    $savedTciHost = $script:TciHost; $savedTciPort = $script:TciPort
    $script:TciHost = $tciHostVal; $script:TciPort = $tciPortVal
    $found = $null
    foreach ($candidate in (Get-TciCandidateHosts)) {
        if (Test-TciPort -IPHost $candidate -Port $tciPortVal) { $found = $candidate; break }
    }
    $script:TciHost = $savedTciHost; $script:TciPort = $savedTciPort
    if ($found) {
        Write-Host "TCI server found at ${found}:${tciPortVal}" -ForegroundColor Green
        Write-MeterLog "INFO" "Setup wizard: TCI test succeeded at ${found}:${tciPortVal}"
    } else {
        Write-Warning "Couldn't reach a TCI server on port $tciPortVal right now. Saving the setting anyway -- just make sure Thetis's TCI Server is running (Setup -> Serial/Network/Midi CAT -> Network -> TCI Server) before you launch this again."
        Write-MeterLog "WARN" "Setup wizard: TCI test found nothing on port $tciPortVal (host setting '$tciHostVal')"
    }

    $config = [ordered]@{
        TxDeviceFriendlyName = $chosenDevice.FriendlyName
        TciHost              = $tciHostVal
        TciPort              = $tciPortVal
        SavedAt              = (Get-Date).ToString("s")
    }
    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
    $config | ConvertTo-Json | Set-Content -Path $ConfigFile -Encoding utf8
    Write-Host ""
    Write-Host "Saved -- this won't ask again unless you run with -Reconfigure." -ForegroundColor Green
    Write-Host ""
    Write-MeterLog "INFO" "Setup wizard complete: TxDevice='$($chosenDevice.FriendlyName)' TciHost=$tciHostVal TciPort=$tciPortVal"
    return $config
}

$script:setupConfig = $null
if ($Reconfigure -or -not (Test-Path $ConfigFile)) {
    $script:setupConfig = Invoke-SetupWizard
} else {
    try {
        $script:setupConfig = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
        Write-Host "[Config] Loaded from $ConfigFile (run with -Reconfigure to change)" -ForegroundColor DarkGray
    } catch {
        Write-Warning "Existing config at $ConfigFile couldn't be read ($($_.Exception.Message)) -- running setup again."
        Write-MeterLog "WARN" "Config load failed ($($_.Exception.Message)) -- re-running setup wizard"
        $script:setupConfig = Invoke-SetupWizard
    }
}

if ($script:setupConfig) {
    $TxDeviceSubstr = $script:setupConfig.TxDeviceFriendlyName
    $TciHost        = $script:setupConfig.TciHost
    $TciPort        = [int]$script:setupConfig.TciPort
    Write-MeterLog "INFO" "Active config: TxDevice='$TxDeviceSubstr' TciHost=$TciHost TciPort=$TciPort"
} else {
    Write-Warning "No configuration available -- falling back to the built-in defaults (TxDeviceSubstr='$TxDeviceSubstr', TciHost='$TciHost', TciPort=$TciPort)."
    Write-MeterLog "WARN" "No config available -- using built-in script defaults"
}

# ── Find TX Capture Device (Voicemeeter B1) ───────────────────────────────────
function Find-WasapiDevice {
    param([string]$Substr, [string]$Flow = "Capture")
    $dataFlow = if ($Flow -eq "Render") { [NAudio.CoreAudioApi.DataFlow]::Render } else { [NAudio.CoreAudioApi.DataFlow]::Capture }
    $enum = [NAudio.CoreAudioApi.MMDeviceEnumerator]::new()
    $devs = $enum.EnumerateAudioEndPoints($dataFlow, [NAudio.CoreAudioApi.DeviceState]::Active)
    foreach ($d in $devs) {
        if ($d.FriendlyName -ilike "*$Substr*") { return $d }
    }
    Write-Warning "TX device not found matching '$Substr'. Available $Flow devices:"
    foreach ($d in $devs) { Write-Host "  - $($d.FriendlyName)" -ForegroundColor Gray }
    return $null
}

$script:txCapture   = $null
$script:txIsFloat   = $true
$script:txBits      = 32
$script:txQueue     = [System.Collections.Concurrent.ConcurrentQueue[byte[]]]::new()
$txDevice = Find-WasapiDevice -Substr $TxDeviceSubstr -Flow "Capture"

if ($txDevice) {
    $script:txCapture = [NAudio.CoreAudioApi.WasapiCapture]::new($txDevice)
    $txFmt            = $script:txCapture.WaveFormat
    $script:txIsFloat = ($txFmt.Encoding -eq [NAudio.Wave.WaveFormatEncoding]::IeeeFloat)
    $script:txBits    = $txFmt.BitsPerSample
    Write-Host "[TX] Found '$($txDevice.FriendlyName)' — $($txFmt.SampleRate)Hz, $($txFmt.Channels)ch, $($txFmt.BitsPerSample)-bit, $($txFmt.Encoding)" -ForegroundColor Green
    Write-MeterLog "INFO" "TX device connected: $($txDevice.FriendlyName) $($txFmt.SampleRate)Hz $($txFmt.Channels)ch $($txFmt.BitsPerSample)-bit $($txFmt.Encoding)"

    # NOTE: Register-ObjectEvent's -Action runs in its own isolated scope — it
    # cannot reliably touch $script: state directly. So, same pattern as the
    # recorder script: the action ONLY copies bytes into a thread-safe queue
    # via -MessageData; the actual RMS/peak math runs later on the UI timer
    # tick, which DOES share script scope.
    $txAction = {
        $ea = $Event.SourceEventArgs
        $n  = $ea.BytesRecorded
        if ($n -gt 0) {
            $copy = New-Object byte[] $n
            [System.Array]::Copy($ea.Buffer, 0, $copy, 0, $n)
            $Event.MessageData.Enqueue($copy)
        }
    }
    $script:txEventSub = Register-ObjectEvent -InputObject $script:txCapture `
        -EventName DataAvailable -Action $txAction -MessageData $script:txQueue

    $script:txCapture.StartRecording()
    $script:txConnected = $true
} else {
    Write-Warning "TX meter will be blank — device not found. Update `$TxDeviceSubstr and restart."
    Write-MeterLog "WARN" "TX device not found matching '$TxDeviceSubstr' — TX meter will be blank"
}

# ── TCI connection (RX) — simplified discovery, meter-only, no MOX/CAT ───────
function Get-TciCandidateHosts {
    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($TciHost -and $TciHost -ne "auto") { $candidates.Add($TciHost) }
    $candidates.Add("127.0.0.1")
    try {
        $listening = Get-NetTCPConnection -State Listen -LocalPort $TciPort -ErrorAction SilentlyContinue
        foreach ($conn in $listening) {
            $addr = $conn.LocalAddress
            if ($addr -and $addr -ne "0.0.0.0" -and $addr -ne "::") { $candidates.Add($addr) }
        }
    } catch {}
    $seen = @{}; $ordered = [System.Collections.Generic.List[string]]::new()
    foreach ($c in $candidates) { if (-not $seen.ContainsKey($c)) { $seen[$c] = $true; $ordered.Add($c) } }
    return $ordered
}

function Test-TciPort {
    param([string]$IPHost, [int]$Port, [int]$TimeoutMs = 500)
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $iar    = $client.BeginConnect($IPHost, $Port, $null, $null)
        $ok     = $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($ok -and $client.Connected) { $client.EndConnect($iar); $client.Close(); return $true }
        $client.Close(); return $false
    } catch { return $false }
}

function Connect-Tci {
    Write-Host "[TCI] Discovering TCI server on port $TciPort..." -ForegroundColor Cyan
    Write-MeterLog "INFO" "TCI connect attempt starting (port $TciPort)"
    foreach ($candidate in (Get-TciCandidateHosts)) {
        if (-not (Test-TciPort -IPHost $candidate -Port $TciPort)) { continue }
        $ws = [System.Net.WebSockets.ClientWebSocket]::new()
        $ws.Options.AddSubProtocol("tci")
        try {
            $ct = [System.Threading.CancellationTokenSource]::new(2000)
            $ws.ConnectAsync([System.Uri]::new("ws://${candidate}:${TciPort}"), $ct.Token).GetAwaiter().GetResult()
            $script:tciWs = $ws
            $script:tciReady = $false
            $script:rxConnected = $false
            $script:recvTask = $null
            $script:recvAccum = $null
            $script:lastRxFrameAt = $null
            Write-Host "[TCI] Connected to ws://${candidate}:${TciPort}" -ForegroundColor Green
            Write-MeterLog "INFO" "TCI connected to ws://${candidate}:${TciPort}"
            return $true
        } catch {
            Write-MeterLog "WARN" "TCI connect to ${candidate}:${TciPort} failed: $($_.Exception.Message)"
            try { $ws.Dispose() } catch {}
        }
    }
    return $false
}

$script:tciWs = $null
if (-not (Connect-Tci)) {
    Write-Warning "[TCI] Could not connect — RX meter will be blank. Make sure Thetis's TCI server is running, then restart this script."
    Write-MeterLog "WARN" "TCI connect failed on all candidates — RX meter will be blank"
}
function Send-TciText {
    param([string]$Msg)
    if (-not $script:tciWs) { return }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Msg)
    $seg   = [System.ArraySegment[byte]]::new($bytes)
    $script:tciWs.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
}

$script:tciHeaderBytes = 64
$script:recvBuffer     = New-Object byte[] 65536
$script:recvTask       = $null
$script:tciReady       = $false
$script:recvAccum      = $null   # List[byte], only non-null while assembling a fragmented message
$script:recvAccumType  = $null   # MessageType of the fragmented message in progress
$script:lastRxFrameAt  = $null   # DateTime of the last successfully processed RX audio frame
$script:lastFragWarnAt = $null   # throttles the fragmentation warning to at most 1 per 2s

function Pump-TciReceive {
    if (-not $script:tciWs -or $script:tciWs.State -ne [System.Net.WebSockets.WebSocketState]::Open) { return }
    try {
        if ($null -eq $script:recvTask) {
            $seg = [System.ArraySegment[byte]]::new($script:recvBuffer, 0, $script:recvBuffer.Length)
            $script:recvTask = $script:tciWs.ReceiveAsync($seg, [System.Threading.CancellationToken]::None)
        }
        if (-not $script:recvTask.Wait(5)) { return }
        $result = $script:recvTask.GetAwaiter().GetResult()
        $script:recvTask = $null

        if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
            Write-Host "[TCI] Server closed the connection." -ForegroundColor DarkYellow
            Write-MeterLog "WARN" "TCI connection closed by server (CloseStatus=$($result.CloseStatus))"
            try { $script:tciWs.Dispose() } catch {}
            $script:tciWs = $null
            return
        }

        # Copy this chunk out of the shared recvBuffer immediately — the buffer
        # gets reused on the very next ReceiveAsync call, so anything we want
        # to keep across fragments has to be copied out now, not referenced.
        $chunk = New-Object byte[] $result.Count
        if ($result.Count -gt 0) {
            [System.Array]::Copy($script:recvBuffer, 0, $chunk, 0, $result.Count)
        }

        # Assemble fragments. Under normal conditions every TCI message (both
        # the small text commands and the ~19KB audio frames) arrives as a
        # single fragment, so this list is created and consumed within one
        # call almost all the time. But the previous version of this script
        # assumed that unconditionally — it stripped the header off of
        # whatever bytes arrived in a *single* recv, even if that recv was
        # only a partial fragment of a bigger message (EndOfMessage=$false).
        # That silently corrupted/truncated the audio payload on any
        # fragmented frame, which would show up as exactly the kind of
        # brief, unexplained RX dropout being investigated here — the
        # recorder's own TCI connection reassembles fragments fine (NAudio /
        # its own read loop handles it), so a fragmentation bug local to
        # THIS script's receive loop is fully consistent with "recorded
        # audio was fine, meter briefly wasn't."
        if ($null -eq $script:recvAccum) {
            $script:recvAccum     = [System.Collections.Generic.List[byte]]::new()
            $script:recvAccumType = $result.MessageType
        }
        if ($chunk.Length -gt 0) { $script:recvAccum.AddRange($chunk) }

        if (-not $result.EndOfMessage) {
            $sinceLast = if ($null -eq $script:lastFragWarnAt) { [double]::MaxValue } else { ((Get-Date) - $script:lastFragWarnAt).TotalMilliseconds }
            if ($sinceLast -ge 2000) {
                Write-MeterLog "WARN" "TCI message fragmented (type=$($script:recvAccumType), $($script:recvAccum.Count) bytes so far) — waiting for continuation"
                $script:lastFragWarnAt = Get-Date
            }
            return   # wait for the rest; nothing to process yet
        }

        $fullBytes = $script:recvAccum.ToArray()
        $msgType   = $script:recvAccumType
        $script:recvAccum     = $null
        $script:recvAccumType = $null

        if ($msgType -eq [System.Net.WebSockets.WebSocketMessageType]::Text) {
            $msg = [System.Text.Encoding]::UTF8.GetString($fullBytes, 0, $fullBytes.Length)
            foreach ($cmd in ($msg -split ';' | Where-Object { $_.Trim() -ne '' })) {
                $cmd = $cmd.Trim()
                if ($cmd -eq 'ready') {
                    Send-TciText "audio_stream_sample_type:float32;"
                    Send-TciText "audio_stream_channels:$Channels;"
                    Send-TciText "audio_stream_samples:2400;"
                    Send-TciText "audio_samplerate:$SampleRate;"
                    Send-TciText "audio_start:$TciTrxIndex;"
                    $script:tciReady = $true
                    Write-MeterLog "INFO" "TCI handshake complete, audio_start sent for trx $TciTrxIndex"
                }
            }
        } elseif ($msgType -eq [System.Net.WebSockets.WebSocketMessageType]::Binary) {
            if ($fullBytes.Length -gt $script:tciHeaderBytes) {
                $now = Get-Date
                if ($null -ne $script:lastRxFrameAt) {
                    $gapMs = ($now - $script:lastRxFrameAt).TotalMilliseconds
                    if ($gapMs -gt $RxFrameGapWarnMs) {
                        Write-MeterLog "WARN" ("RX frame gap {0:0}ms (threshold {1}ms)" -f $gapMs, $RxFrameGapWarnMs)
                    }
                }
                $script:lastRxFrameAt = $now
                $script:rxConnected = $true
                $audioByteCount = $fullBytes.Length - $script:tciHeaderBytes
                $audioBytes = New-Object byte[] $audioByteCount
                [System.Array]::Copy($fullBytes, $script:tciHeaderBytes, $audioBytes, 0, $audioByteCount)
                $rmsDb = 0.0; $peakDb = 0.0
                # NOTE: [ref]$script:rxEmaMeanSq directly was not reliably
                # writing back — the EMA state was effectively resetting to
                # its seed almost every call instead of persisting, which is
                # why the RMS bar was stuck near a fixed value regardless of
                # actual audio. Using a local var for the ref call, then an
                # explicit copy back to script scope, is the same pattern
                # that already works reliably for rmsDb/peakDb below.
                $localEma = $script:rxEmaMeanSq
                [ThetisMeter.LevelCalc]::ProcessFloat($audioBytes, $audioByteCount, [ref]$localEma, $rmsWindowCoeff, [ref]$rmsDb, [ref]$peakDb)
                $script:rxEmaMeanSq = $localEma
                $script:rxRmsDb = $rmsDb
                Update-PeakHold -Source "rx" -InstantPeakDb $peakDb -DecayDbPerCall 0
            }
        }
    } catch {
        Write-Host "[UI] Pump-TciReceive error at line $($_.InvocationInfo.ScriptLineNumber): '$($_.InvocationInfo.Line.Trim())' -- $($_.Exception.Message)" -ForegroundColor DarkYellow
        Write-MeterLog "ERROR" "Pump-TciReceive line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)"
        # A receive that throws mid-flight usually means the socket is dead
        # (reset, timeout, etc.) — drop it so the tick loop's reconnect logic
        # picks it back up, instead of spinning on the same broken task/state.
        try { if ($script:tciWs) { $script:tciWs.Dispose() } } catch {}
        $script:tciWs = $null
        $script:recvTask = $null
        $script:recvAccum = $null
    }
}

# ── UI ─────────────────────────────────────────────────────────────────────
function DbToX {
    param([double]$Db, [int]$Width)
    $clamped = [System.Math]::Max($MeterFloorDb, [System.Math]::Min($MeterCeilDb, $Db))
    $frac    = ($clamped - $MeterFloorDb) / ($MeterCeilDb - $MeterFloorDb)
    return [int]($frac * $Width)
}

function Draw-Meter {
    param($Graphics, [System.Drawing.Rectangle]$Rect, [double]$RmsDb, [double]$PeakDb, [bool]$Clipping)

    $g = $Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

    # Background track
    $bg = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(30,30,30))
    $g.FillRectangle($bg, $Rect)

    # Zone bands (drawn as background tint under the bar)
    $zoneTargetX0 = $Rect.X + (DbToX $TargetLowDb $Rect.Width)
    $zoneTargetX1 = $Rect.X + (DbToX $TargetHighDb $Rect.Width)
    $zoneHotX     = $Rect.X + (DbToX $HotDb $Rect.Width)
    $zoneClipX    = $Rect.X + (DbToX $ClipDb $Rect.Width)
    $zoneEndX     = $Rect.X + $Rect.Width

    $targetBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(60,80,60))
    $g.FillRectangle($targetBrush, $zoneTargetX0, $Rect.Y, [System.Math]::Max(1,$zoneTargetX1-$zoneTargetX0), $Rect.Height)

    # Static "hot" (yellow) and "clip" (red) reference bands — these mark where
    # those zones sit on the scale even when the live level isn't there, so
    # you're not relying on the bar itself to ever visit them to know where
    # they are (e.g. a quiet resting signal shows no hint otherwise).
    $hotBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(70,65,55,20))
    $g.FillRectangle($hotBrush, $zoneHotX, $Rect.Y, [System.Math]::Max(1,$zoneClipX-$zoneHotX), $Rect.Height)
    $clipBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(70,90,20,20))
    $g.FillRectangle($clipBrush, $zoneClipX, $Rect.Y, [System.Math]::Max(1,$zoneEndX-$zoneClipX), $Rect.Height)

    # RMS bar
    $barW = (DbToX $RmsDb $Rect.Width)
    $barColor = if ($RmsDb -ge $ClipDb) { [System.Drawing.Color]::FromArgb(220,40,40) }
                elseif ($RmsDb -ge $HotDb) { [System.Drawing.Color]::FromArgb(230,190,40) }
                else { [System.Drawing.Color]::FromArgb(70,200,90) }
    $barBrush = [System.Drawing.SolidBrush]::new($barColor)
    if ($barW -gt 0) { $g.FillRectangle($barBrush, $Rect.X, $Rect.Y, $barW, $Rect.Height) }

    # Peak-hold marker
    $peakX = $Rect.X + (DbToX $PeakDb $Rect.Width)
    $peakPen = [System.Drawing.Pen]::new([System.Drawing.Color]::White, 2)
    $g.DrawLine($peakPen, $peakX, $Rect.Y, $peakX, $Rect.Y + $Rect.Height)

    # Zone edge ticks (target band + hot/clip boundary)
    $tickPen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(120,255,255,255), 1)
    $g.DrawLine($tickPen, $zoneTargetX0, $Rect.Y, $zoneTargetX0, $Rect.Y + $Rect.Height)
    $g.DrawLine($tickPen, $zoneTargetX1, $Rect.Y, $zoneTargetX1, $Rect.Y + $Rect.Height)
    $g.DrawLine($tickPen, $zoneHotX, $Rect.Y, $zoneHotX, $Rect.Y + $Rect.Height)
    $g.DrawLine($tickPen, $zoneClipX, $Rect.Y, $zoneClipX, $Rect.Y + $Rect.Height)

    # Border
    $g.DrawRectangle([System.Drawing.Pens]::Gray, $Rect)

    # Clip flash border
    if ($Clipping) {
        $clipPen = [System.Drawing.Pen]::new([System.Drawing.Color]::Red, 3)
        $g.DrawRectangle($clipPen, $Rect.X+1, $Rect.Y+1, $Rect.Width-2, $Rect.Height-2)
    }
}

# Panels don't double-buffer by default, which causes visible flicker at
# ~25fps (each repaint briefly erases before drawing). DoubleBuffered is a
# protected property on Control, but PowerShell can still set it via
# reflection — this is the standard fix for WinForms flicker in PS scripts.
function Enable-DoubleBuffer {
    param([System.Windows.Forms.Control]$Ctrl)
    try {
        $prop = [System.Windows.Forms.Control].GetProperty("DoubleBuffered", [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic)
        if ($prop) {
            $prop.SetValue($Ctrl, $true, $null)
        } else {
            Write-Host "[UI] DoubleBuffered property not found via reflection — skipping (cosmetic only, meter still works)." -ForegroundColor DarkYellow
        }
    } catch {
        Write-Host "[UI] Could not enable double-buffering — skipping (cosmetic only, meter still works): $_" -ForegroundColor DarkYellow
    }
}

$form = [System.Windows.Forms.Form]::new()
$form.Text = "Thetis Level Meter — W4ORS"
$form.ClientSize = [System.Drawing.Size]::new(560, 320)
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
$form.MaximizeBox = $false
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.BackColor = [System.Drawing.Color]::FromArgb(20,20,20)

$fontLabel = [System.Drawing.Font]::new("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$fontVal   = [System.Drawing.Font]::new("Consolas", 11)
$fontVal2  = [System.Drawing.Font]::new("Consolas", 9)
$fontLegend= [System.Drawing.Font]::new("Segoe UI", 8)

$lblRx = [System.Windows.Forms.Label]::new()
$lblRx.Text = "RX — Thetis"
$lblRx.ForeColor = [System.Drawing.Color]::White
$lblRx.Font = $fontLabel
$lblRx.Location = [System.Drawing.Point]::new(20, 20)
$lblRx.AutoSize = $true
$form.Controls.Add($lblRx)

$panelRx = [System.Windows.Forms.Panel]::new()
$panelRx.Location = [System.Drawing.Point]::new(20, 50)
$panelRx.Size = [System.Drawing.Size]::new(520, 34)
Enable-DoubleBuffer -Ctrl $panelRx
$form.Controls.Add($panelRx)

$valRx = [System.Windows.Forms.Label]::new()
$valRx.ForeColor = [System.Drawing.Color]::LightGray
$valRx.Font = $fontVal
$valRx.Location = [System.Drawing.Point]::new(20, 88)
$valRx.AutoSize = $true
$form.Controls.Add($valRx)

$valRx2 = [System.Windows.Forms.Label]::new()
$valRx2.ForeColor = [System.Drawing.Color]::DarkGray
$valRx2.Font = $fontVal2
$valRx2.Location = [System.Drawing.Point]::new(20, 108)
$valRx2.AutoSize = $true
$form.Controls.Add($valRx2)

$lblTx = [System.Windows.Forms.Label]::new()
$lblTx.Text = "TX — Voicemeeter B1"
$lblTx.ForeColor = [System.Drawing.Color]::White
$lblTx.Font = $fontLabel
$lblTx.Location = [System.Drawing.Point]::new(20, 142)
$lblTx.AutoSize = $true
$form.Controls.Add($lblTx)

$panelTx = [System.Windows.Forms.Panel]::new()
$panelTx.Location = [System.Drawing.Point]::new(20, 172)
$panelTx.Size = [System.Drawing.Size]::new(520, 34)
Enable-DoubleBuffer -Ctrl $panelTx
$form.Controls.Add($panelTx)

$valTx = [System.Windows.Forms.Label]::new()
$valTx.ForeColor = [System.Drawing.Color]::LightGray
$valTx.Font = $fontVal
$valTx.Location = [System.Drawing.Point]::new(20, 210)
$valTx.AutoSize = $true
$form.Controls.Add($valTx)

$valTx2 = [System.Windows.Forms.Label]::new()
$valTx2.ForeColor = [System.Drawing.Color]::DarkGray
$valTx2.Font = $fontVal2
$valTx2.Location = [System.Drawing.Point]::new(20, 230)
$valTx2.AutoSize = $true
$form.Controls.Add($valTx2)

$legend = [System.Windows.Forms.Label]::new()
$legend.Text = "Bright green = target (-22..-20dB)  |  dim yellow/red = hot/clip zones`nwhite line = peak-hold  |  red border = clipped"
$legend.ForeColor = [System.Drawing.Color]::Gray
$legend.Font = $fontLegend
$legend.Location = [System.Drawing.Point]::new(20, 264)
$legend.Size = [System.Drawing.Size]::new(520, 34)
$legend.AutoSize = $false
$form.Controls.Add($legend)

$panelRx.Add_Paint({
    param($s, $e)
    try {
        if ($null -ne $script:rxInvalidateAt) {
            $lagMs = ((Get-Date) - $script:rxInvalidateAt).TotalMilliseconds
            if ($lagMs -gt $UiStallWarnMs) {
                Write-UiStallWarn ("RX paint lagged {0:0}ms behind Invalidate() -- last RmsDb={1:0.0}" -f $lagMs, $script:rxRmsDb)
            }
        }
        $clipping = ((Get-Date) -lt $script:rxClipUntil)
        Draw-Meter -Graphics $e.Graphics -Rect ([System.Drawing.Rectangle]::new(0,0,$panelRx.Width,$panelRx.Height)) -RmsDb $script:rxRmsDb -PeakDb $script:rxPeakHoldDb -Clipping $clipping
    } catch {
        Write-Host "[UI] RX paint error at line $($_.InvocationInfo.ScriptLineNumber): '$($_.InvocationInfo.Line.Trim())' -- $($_.Exception.Message)" -ForegroundColor DarkYellow
        Write-MeterLog "ERROR" "RX paint error line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)"
    }
})
$panelTx.Add_Paint({
    param($s, $e)
    try {
        if ($null -ne $script:txInvalidateAt) {
            $lagMs = ((Get-Date) - $script:txInvalidateAt).TotalMilliseconds
            if ($lagMs -gt $UiStallWarnMs) {
                Write-UiStallWarn ("TX paint lagged {0:0}ms behind Invalidate() -- last RmsDb={1:0.0}" -f $lagMs, $script:txRmsDb)
            }
        }
        $clipping = ((Get-Date) -lt $script:txClipUntil)
        Draw-Meter -Graphics $e.Graphics -Rect ([System.Drawing.Rectangle]::new(0,0,$panelTx.Width,$panelTx.Height)) -RmsDb $script:txRmsDb -PeakDb $script:txPeakHoldDb -Clipping $clipping
    } catch {
        Write-Host "[UI] TX paint error at line $($_.InvocationInfo.ScriptLineNumber): '$($_.InvocationInfo.Line.Trim())' -- $($_.Exception.Message)" -ForegroundColor DarkYellow
        Write-MeterLog "ERROR" "TX paint error line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)"
    }
})

$timer = [System.Windows.Forms.Timer]::new()
$timer.Interval = 40   # ~25fps
$peakDecayPerTick = $PeakDecayDbPerSec * ($timer.Interval / 1000.0)
$script:lastReconnectAttempt = [DateTime]::MinValue
$ReconnectIntervalBaseMs = 3000    # first retry delay
$ReconnectIntervalMaxMs  = 60000   # cap — never wait longer than this between tries
$script:reconnectIntervalMs = $ReconnectIntervalBaseMs
$script:lastLoggedRxStatus = $null

# UI-thread health tracking — this is aimed squarely at the "recorder had
# audio the whole time but the meter looked blank" reports. If the receive
# side logs completely clean (as it did) the remaining candidate is the UI
# thread itself falling behind: either the Tick handler firing late (thread
# busy/blocked elsewhere) or Invalidate() being called on time but the actual
# WM_PAINT not getting serviced promptly. Both get logged, throttled to at
# most once per 2s so a rough patch doesn't flood the file.
$script:lastTickAt        = [DateTime]::MinValue
$script:rxInvalidateAt    = $null
$script:txInvalidateAt    = $null
$script:lastUiStallWarnAt = $null

function Write-UiStallWarn {
    param([string]$Msg)
    $sinceLast = if ($null -eq $script:lastUiStallWarnAt) { [double]::MaxValue } else { ((Get-Date) - $script:lastUiStallWarnAt).TotalMilliseconds }
    if ($sinceLast -ge 2000) {
        Write-MeterLog "WARN" $Msg
        $script:lastUiStallWarnAt = Get-Date
    }
}

$timer.Add_Tick({
    try {
        # If this tick fired much later than the 40ms interval, the UI
        # thread was stuck doing something else (a slow paint, a blocked
        # call, GC, whatever) right up until now — worth knowing about on
        # its own, independent of whether data was still arriving fine.
        $now = Get-Date
        if ($script:lastTickAt -ne [DateTime]::MinValue) {
            $tickGapMs = ($now - $script:lastTickAt).TotalMilliseconds
            if ($tickGapMs -gt ($timer.Interval + $UiStallWarnMs)) {
                Write-UiStallWarn ("UI tick fired late: {0:0}ms since previous tick (expected ~{1}ms) — UI thread was busy" -f $tickGapMs, $timer.Interval)
            }
        }
        $script:lastTickAt = $now

        # If the TCI socket has dropped (server hiccup, network blip, etc.),
        # Pump-TciReceive nulls it out rather than spinning on a dead
        # connection. Retry periodically instead of requiring a script
        # restart — this also closes the gap where the RX meter would
        # otherwise just freeze/blank for the rest of the session.
        #
        # Backoff: each failed attempt doubles the wait (3s, 6s, 12s, 24s,
        # 48s, then capped at 60s) so a TCI server that's down for an hour
        # produces a handful of log lines, not one every 3 seconds. Resets
        # back to the base delay as soon as a reconnect succeeds.
        if (-not $script:tciWs -and ((Get-Date) - $script:lastReconnectAttempt).TotalMilliseconds -ge $script:reconnectIntervalMs) {
            $script:lastReconnectAttempt = Get-Date
            Write-MeterLog "INFO" "Attempting TCI reconnect (next retry in $([int]($script:reconnectIntervalMs/1000))s if this fails)..."
            if (Connect-Tci) {
                Write-MeterLog "INFO" "TCI reconnect succeeded"
                $script:reconnectIntervalMs = $ReconnectIntervalBaseMs
            } else {
                $script:reconnectIntervalMs = [System.Math]::Min($script:reconnectIntervalMs * 2, $ReconnectIntervalMaxMs)
            }
        }

        Pump-TciReceive

        # Log RX status transitions (not every tick — only on change) so the
        # log shows exactly when/if the meter thought RX audio came or went,
        # which is the thing to correlate against what you saw on screen.
        $rxStatusNow = if (-not $script:tciWs) { "no-connection" } elseif (-not $script:rxConnected) { "waiting-for-audio" } else { "connected" }
        if ($rxStatusNow -ne $script:lastLoggedRxStatus) {
            Write-MeterLog "INFO" "RX status: $rxStatusNow"
            $script:lastLoggedRxStatus = $rxStatusNow
        }

        # Drain any captured TX (Voicemeeter B1) buffers queued by the WASAPI
        # event handler and run the RMS/peak math here, on the UI thread — this
        # is where $script: state is safe to touch (see note above the
        # Register-ObjectEvent call).
        $buf = $null
        while ($script:txQueue -and $script:txQueue.TryDequeue([ref]$buf)) {
            $rmsDb = 0.0; $peakDb = 0.0
            # Same fix as the RX side: local var for the ref call, explicit
            # copy back to script scope, instead of [ref]$script:txEmaMeanSq
            # directly (which was not persisting between calls).
            $localEma = $script:txEmaMeanSq
            if ($script:txIsFloat) {
                [ThetisMeter.LevelCalc]::ProcessFloat($buf, $buf.Length, [ref]$localEma, $rmsWindowCoeff, [ref]$rmsDb, [ref]$peakDb)
            } elseif ($script:txBits -eq 16) {
                [ThetisMeter.LevelCalc]::ProcessInt16($buf, $buf.Length, [ref]$localEma, $rmsWindowCoeff, [ref]$rmsDb, [ref]$peakDb)
            } else {
                continue
            }
            $script:txEmaMeanSq = $localEma
            $script:txRmsDb = $rmsDb
            Update-PeakHold -Source "tx" -InstantPeakDb $peakDb -DecayDbPerCall 0
        }

        # Peak-hold decay
        $script:rxPeakHoldDb = [System.Math]::Max($script:rxRmsDb, $script:rxPeakHoldDb - $peakDecayPerTick)
        $script:txPeakHoldDb = [System.Math]::Max($script:txRmsDb, $script:txPeakHoldDb - $peakDecayPerTick)

        $rxStatus = if (-not $script:tciWs) { " [no TCI connection]" } elseif (-not $script:rxConnected) { " [waiting for audio...]" } else { "" }
        $txStatus = if (-not $script:txConnected) { " [device not found]" } else { "" }

        $valRx.Text = ("RMS {0,6:0.0} dB   Peak {1,6:0.0} dB{2}" -f $script:rxRmsDb, $script:rxPeakHoldDb, $rxStatus)
        $valTx.Text = ("RMS {0,6:0.0} dB   Peak {1,6:0.0} dB{2}" -f $script:txRmsDb, $script:txPeakHoldDb, $txStatus)

        $rxStats = Get-WindowedStats -Source "rx" -PeakWindowSec $Peak3sWindowSec -AvgWindowSec $Avg10sWindowSec
        $txStats = Get-WindowedStats -Source "tx" -PeakWindowSec $Peak3sWindowSec -AvgWindowSec $Avg10sWindowSec
        $valRx2.Text = ("Peak (last {0:0}s) {1,6:0.0} dB   Avg (last {2:0}s) {3,6:0.0} dB" -f $Peak3sWindowSec, $rxStats.Peak3s, $Avg10sWindowSec, $rxStats.Avg10s)
        $valTx2.Text = ("Peak (last {0:0}s) {1,6:0.0} dB   Avg (last {2:0}s) {3,6:0.0} dB" -f $Peak3sWindowSec, $txStats.Peak3s, $Avg10sWindowSec, $txStats.Avg10s)

        $script:rxInvalidateAt = Get-Date
        $panelRx.Invalidate()
        $script:txInvalidateAt = Get-Date
        $panelTx.Invalidate()
    } catch {
        Write-Host "[UI] Tick error at line $($_.InvocationInfo.ScriptLineNumber): '$($_.InvocationInfo.Line.Trim())' -- $($_.Exception.Message)" -ForegroundColor DarkYellow
        Write-MeterLog "ERROR" "Tick error line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)"
    }
})

$form.Add_FormClosing({
    $script:closing = $true
    $timer.Stop()
    Write-MeterLog "INFO" "=== ThetisLevelMeter closing ==="
    try { if ($script:txCapture) { $script:txCapture.StopRecording(); $script:txCapture.Dispose() } } catch {}
    try { if ($script:txEventSub) { Unregister-Event -SourceIdentifier $script:txEventSub.Name -ErrorAction SilentlyContinue } } catch {}
    try {
        if ($script:tciWs -and $script:tciWs.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            Send-TciText "audio_stop:$TciTrxIndex;"
            $script:tciWs.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "Meter closed", [System.Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
        }
    } catch {}
    try { if ($script:tciWs) { $script:tciWs.Dispose() } } catch {}
})

$timer.Start()
[System.Windows.Forms.Application]::Run($form)
