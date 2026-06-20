# oci-grab-arm

A small PowerShell script that retries launching an **Oracle Cloud Always Free Ampere A1** instance until capacity becomes available — so you don't have to sit clicking "Create" in the console while it returns *"Out of host capacity."*

It runs locally on Windows via the OCI CLI (no Cloud Shell session to keep alive), paces itself to stay under OCI's API rate limit, and stops safely the moment it grabs a slot.

## Why this exists

Free-tier ARM (A1) capacity in popular regions is scarce. When someone releases capacity it's claimed within seconds, so manual retries rarely catch it. This script loops across all availability domains at a polite cadence and launches the instance the instant a slot opens.

## What it does

- Cycles all availability domains, retrying until a launch succeeds.
- Uses `--no-retry` so the loop sets the pace instead of the CLI stalling ~2 min on internal retries.
- Backs off on HTTP 429, retrying the same AD up to twice before moving on.
- **Won't create a duplicate:** checks for an existing instance at startup and stops on `LimitExceeded`.
- **Won't loop forever on a misconfig:** unrecognized errors (bad OCID, bad SSH key, auth) stop it after a few tries.
- Confirms `RUNNING` via a separate poll on success, then beeps and exits.
- Logs every attempt to `oci_grab_arm_log.txt` (gitignored), with a live countdown between tries.

## Requirements

- Windows + PowerShell
- [OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm) installed and configured (`oci setup config` → creates `~/.oci/config` with an API key)
- An SSH public key at `~/.ssh/id_ed25519.pub` (or edit `$SSH_KEY_FILE` in the script)

## Setup

1. Copy the config template and fill in your own OCIDs:

   ```powershell
   Copy-Item oci_grab_arm.config.example.ps1 oci_grab_arm.config.ps1
   ```

   Edit `oci_grab_arm.config.ps1`:

   ```powershell
   $COMPARTMENT_ID = "ocid1.tenancy.oc1..your-tenancy-ocid"
   $SUBNET_ID      = "ocid1.subnet.oc1.<region>.your-subnet-ocid"
   ```

   This file is gitignored, so your OCIDs never get committed.

2. Run it:

   ```powershell
   ./oci_grab_arm.ps1
   ```

   > If PowerShell blocks it with an execution-policy error, run it as
   > `powershell -ExecutionPolicy Bypass -File .\oci_grab_arm.ps1`, or allow local scripts once with
   > `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

   Leave the window open and stop your PC from sleeping. On success you'll see a `CAPACITY FOUND` banner with the instance OCID, a `CONFIRMED RUNNING` line, and three beeps.

## Configuration (top of `oci_grab_arm.ps1`)

| Variable | Default | Meaning |
|---|---|---|
| `$OCPUS` / `$MEM_GB` | `1` / `6` | Shape size. Free max is **2 OCPU / 12 GB**. A smaller shape is easier to place. |
| `$BOOT_GB` | `100` | Boot volume size (GB). Free tier allows 200 GB total block storage. |
| `$BETWEEN_ADS` | `45` | Seconds between AD attempts within a round (+ small jitter). |
| `$SLEEP_SECONDS` | `60` | Pause at the end of a full round. |
| `$RL_BACKOFF_0` | `20` | Initial 429 cooldown; doubles on consecutive 429s, capped at 300s. |

## A note on rate limits & being a good citizen

The defaults run roughly one launch call per minute — in line with what the established community scripts use. **Don't tighten them aggressively.** Hammering the LaunchInstance endpoint trips OCI's per-user throttle (HTTP 429) and sustained abuse can get a free-tier account flagged. Slower polling costs you almost nothing: freed capacity doesn't vanish in seconds for most accounts, and the truly reliable fix for chronic "out of capacity" is upgrading to **Pay As You Go** (still $0 for Always Free resources, with capacity priority).

## Notes

- The instance launches with **no public IP** (`--assign-public-ip false`) to respect the free 2-ephemeral-IP limit. Assign one afterward in the console (Instance → Attached VNICs → IPv4 → Edit).
- Free A1 allowance is **2 OCPU / 12 GB / 200 GB block storage** total (as of June 2026). Requesting `1/6` leaves room for a second instance.

## Disclaimer

Use at your own risk. This is an unofficial tool, not affiliated with Oracle. You are responsible for staying within Oracle's [Free Tier terms](https://www.oracle.com/cloud/free/) and acceptable-use policy. Run it at a reasonable cadence.
