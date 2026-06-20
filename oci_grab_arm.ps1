# Retry-launch a free OCI Ampere A1 instance until capacity is available.
# Runs locally on Windows via the OCI CLI. Leave the window open until it lands.

# Personal OCIDs live in oci_grab_arm.config.ps1 (gitignored); copy the .example file to create it.
$ConfigFile = Join-Path $PSScriptRoot "oci_grab_arm.config.ps1"
if (-not (Test-Path $ConfigFile)) {
  Write-Host "ERROR: $ConfigFile not found."
  Write-Host "Copy oci_grab_arm.config.example.ps1 to oci_grab_arm.config.ps1 and fill in your OCI values."
  exit 1
}
. $ConfigFile
if (-not $COMPARTMENT_ID -or -not $SUBNET_ID) {
  Write-Host "ERROR: COMPARTMENT_ID and SUBNET_ID must both be set in $ConfigFile."; exit 1
}

$OCPUS          = 1
$MEM_GB         = 6
$BOOT_GB        = 100    # boot volume GB (free tier: 200 total)
$SLEEP_SECONDS  = 60     # pause between full AD rounds
$BETWEEN_ADS    = 45     # pause between ADs within a round (plus jitter)
$RL_BACKOFF_0   = 20     # 429 cooldown; doubles per consecutive 429, capped at 300

$LOG_FILE = Join-Path $PSScriptRoot "oci_grab_arm_log.txt"
function Log($m) {
  Write-Host $m
  Add-Content -LiteralPath $LOG_FILE -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m)
}

# One-line countdown shown during sleeps (console only, not logged).
function Wait-WithCountdown([int]$Seconds, [string]$Label) {
  for ($s = $Seconds; $s -gt 0; $s--) {
    Write-Host ("`r   ...{0}: {1,3}s remaining " -f $Label, $s) -NoNewline
    Start-Sleep -Seconds 1
  }
  Write-Host ("`r" + (' ' * 50) + "`r") -NoNewline   # wipe the line so the next log entry is clean
}

Log "===== run started $(Get-Date) (PID $PID) ====="

$DISPLAY_NAME   = "portfolio-apps"
$SSH_KEY_FILE   = "$env:USERPROFILE\.ssh\id_ed25519.pub"

if (-not (Test-Path $SSH_KEY_FILE)) { Log "ERROR: $SSH_KEY_FILE not found."; exit 1 }

# Shape config via a file to avoid JSON-quoting issues on Windows
$shapePath = "$env:USERPROFILE\oci_shape.json"
"{`"ocpus`":$OCPUS,`"memoryInGBs`":$MEM_GB}" | Out-File -Encoding ascii $shapePath
$shapeArg = ("file://$shapePath") -replace '\\','/'

Log "Resolving Ubuntu 24.04 aarch64 image..."
$IMAGE_ID = (oci compute image list --compartment-id $COMPARTMENT_ID `
  --operating-system "Canonical Ubuntu" --operating-system-version "24.04" `
  --shape "VM.Standard.A1.Flex" --sort-by TIMECREATED --sort-order DESC `
  --query "data[0].id" --raw-output)
if (-not $IMAGE_ID) { Log "ERROR: no image found."; exit 1 }
Log "Image: $IMAGE_ID"

# PS 5.1's ConvertFrom-Json emits an array as one object; join the lines and cast to [string[]] to get a flat list.
$adsText = (oci iam availability-domain list --compartment-id $COMPARTMENT_ID `
  --query "data[].name" --raw-output) -join "`n"
$ADS = [string[]]($adsText | ConvertFrom-Json)
if (-not $ADS -or $ADS.Count -eq 0) { Log "ERROR: could not list availability domains (auth/network?). Exiting."; exit 1 }
Log("ADs: " + ($ADS -join ", "))

# Skip if an instance of this name is already running (avoids a duplicate; the quota allows two).
$existingId = (oci compute instance list --compartment-id $COMPARTMENT_ID `
  --display-name $DISPLAY_NAME --lifecycle-state RUNNING `
  --query "data[0].id" --raw-output 2>$null)
if ($existingId) {
  Log "An instance named '$DISPLAY_NAME' is already RUNNING ($existingId). Nothing to do; exiting."
  exit 0
}

Log "Starting retry loop. Leave running. Ctrl-C to stop."

$attempt = 0
$RL_BACKOFF = $RL_BACKOFF_0
$unknownStreak = 0     # consecutive unexpected errors; bail if one persists
while ($true) {
  foreach ($AD in $ADS) {
    $retrySameAd = $true
    $rlTries = 0          # 429s on this AD; move on after 2
    while ($retrySameAd) {
      $retrySameAd = $false
      $attempt++
      Log("[{0}] attempt #{1} -> {2}" -f (Get-Date -Format HH:mm:ss), $attempt, $AD)
      # --no-retry: the CLI otherwise retries ~7x internally (~2 min) before returning; we pace the loop.
      $OUT = oci compute instance launch --no-retry --availability-domain $AD `
        --compartment-id $COMPARTMENT_ID --shape "VM.Standard.A1.Flex" `
        --shape-config $shapeArg --image-id $IMAGE_ID --subnet-id $SUBNET_ID `
        --assign-public-ip false --display-name $DISPLAY_NAME `
        --boot-volume-size-in-gbs $BOOT_GB `
        --ssh-authorized-keys-file $SSH_KEY_FILE 2>&1
      # No --wait-for-state: a 200 means capacity is granted; we confirm RUNNING separately below.
      if ($LASTEXITCODE -eq 0) {
        Log "=================================================="
        Log " CAPACITY FOUND - launch accepted on $AD at $(Get-Date)"
        $instId = ([regex]::Match(($OUT -join "`n"), 'ocid1\.instance\.[a-z0-9\.\-]+')).Value
        if ($instId) { Log " Instance: $instId" }

        # Confirm RUNNING with a separate, read-only poll (never re-launches, so no duplicate risk).
        if ($instId) {
          $state = "PROVISIONING"
          $deadline = (Get-Date).AddMinutes(10)
          while ((Get-Date) -lt $deadline) {
            $got = (oci compute instance get --instance-id $instId `
              --query 'data."lifecycle-state"' --raw-output 2>$null)
            if ($got) { $state = $got }
            if ($state -in @("RUNNING","TERMINATED","TERMINATING","STOPPED")) { break }
            Wait-WithCountdown 15 "confirming RUNNING (now $state)"
          }
          if ($state -eq "RUNNING") { Log " CONFIRMED RUNNING." }
          else { Log " Instance state is '$state' (not RUNNING within 10 min) - check the OCI console." }
        } else {
          Log " Could not parse the instance OCID from output - verify in the OCI console."
        }

        Log " Note: NO public IP (--assign-public-ip false). Assign one in the console"
        Log " (Instance -> Attached VNICs -> IPv4 -> Edit -> ephemeral) to reach your apps."
        Log "=================================================="
        [console]::beep(880,400); [console]::beep(880,400); [console]::beep(880,400)
        exit 0
      } else {
        $msgLine = ($OUT | Select-String -Pattern '"message"' | Select-Object -First 1)
        $reason = if ($msgLine) { ($msgLine -replace '.*"message":\s*"','' -replace '".*','').Trim() } else { "see output" }
        if ($OUT -match 'Too many requests' -or $OUT -match 'TooManyRequests') {
          $unknownStreak = 0
          $rlTries++
          if ($rlTries -ge 2) {
            Log("   ...RATE LIMITED ($reason) x$rlTries on $AD; moving to next AD")
            $RL_BACKOFF = [Math]::Min($RL_BACKOFF * 2, 300)
          } else {
            Log("   ...RATE LIMITED ($reason); cooling down {0}s, then retrying same AD" -f $RL_BACKOFF)
            Wait-WithCountdown ($RL_BACKOFF + (Get-Random -Minimum 0 -Maximum 5)) "rate-limit cooldown"
            $RL_BACKOFF = [Math]::Min($RL_BACKOFF * 2, 300)
            $retrySameAd = $true
          }
        } elseif ($OUT -match 'LimitExceeded' -or $OUT -match 'service limits were exceeded') {
          # Already at quota; capacity isn't the blocker, so stop.
          Log "   ...LIMIT REACHED ($reason)."
          Log " You appear to already have an A1 instance using the free quota. Stopping."
          Log " Check the OCI console; if it's stale/terminated or you want another, free the"
          Log " quota or change `$DISPLAY_NAME and re-run."
          exit 1
        } elseif ($OUT -match 'Out of host capacity' -or $OUT -match 'InternalError' -or $OUT -match 'Bad Gateway' -or $OUT -match 'ServiceUnavailable' -or $OUT -match 'TooBusy') {
          Log "   ...no luck ($reason); continuing"
          $unknownStreak = 0
          $RL_BACKOFF = $RL_BACKOFF_0
        } else {
          # Unrecognized error - likely a config/permission problem; stop if it persists.
          $unknownStreak++
          Log("   ...unexpected error ($reason) [{0}/5]" -f $unknownStreak)
          if ($unknownStreak -ge 5) {
            Log " FATAL: same non-capacity error 5x in a row - almost certainly a config/permission"
            Log " problem, not capacity. Stopping. Full last output:"
            $OUT | ForEach-Object { Log ("   " + $_) }
            exit 1
          }
          $RL_BACKOFF = $RL_BACKOFF_0
        }
      }
    }
    # No between-AD pause after the last AD; the round sleep covers that gap.
    if ($AD -ne $ADS[-1]) {
      Wait-WithCountdown ($BETWEEN_ADS + (Get-Random -Minimum 0 -Maximum 4)) "next attempt"   # jitter breaks fixed-cadence sync
    }
  }
  Log("[{0}] all ADs out; new round" -f (Get-Date -Format HH:mm:ss))
  if ($SLEEP_SECONDS -gt 0) { Wait-WithCountdown $SLEEP_SECONDS "new round" }
}
