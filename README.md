🇺🇸 English | 🇧🇷 [Português](README.pt-br.md)

# Issabel PBX Migration Toolkit

Migrates an Issabel PBX from one VM to another, preserving extensions, trunks, CDR history, and call recordings.

## Why two modes

Source environment: multi-tenant, each customer on their own VM, provisioned on demand. Since each installation pulled the latest version from the official repository at creation time, the fleet ended up with fairly different versions across VMs. A VM created two years ago could be on an older major version, or on the same major version but a much older build.

This creates two different migration scenarios that can't be handled the same way:

- **Source on Issabel 4** (previous major version): Issabel has a native Migrate function built exactly for this. You import a backup generated on a fresh Issabel 5 through it. It's the most reliable path when available, so the `legacy` mode uses this tool instead of trying to manually rebuild something the system already solves.
- **Source already on Issabel 5, older build**: no major version jump here, but after enough time between builds, a plain backup import stops working because modules and schema have drifted too far apart. The native Migrate function doesn't help in this case — it's built for major version jumps, not build drift. The `current` mode does a manual tarball extraction and rebuilds the AstDB from scratch.

The script covers both; you choose the mode at the start of execution.

## What each step does

| Step | `legacy` | `current` |
|---|---|---|
| 0. Trunks | Disables and removes only the associated SIP registration records | Removes trunks entirely |
| 1. Backup | Issabel's native Migrate function (`issabel_migration.sh`), to import a backup from Issabel 4 into Issabel 5 | Manual tarball extraction + AstDB rebuild (device state/hints) |
| 2. Network | External IP, localnet, SIP/SIP-TLS ports, `strictrtp`. Same in both modes |
| 3. CDR | Dump (configurable period or full history) + import, with schema fix |
| 4. Recordings | rsync of `/var/spool/asterisk/monitor/`. Same in both modes |

Steps are independent — run only the ones that make sense for the specific migration.

## How to run it

The script runs on your own computer, not on the VMs. It connects via SSH to both the source and destination from your local machine. Credentials are also set locally, in your terminal, before calling the script — never hardcoded inside the `.sh` file itself:

```bash
export PBX_MYSQL_USER="asteriskuser"
export PBX_MYSQL_PASS="your-password"
export PBX_MYSQL_ROOT_PASS="your-root-password"
export PBX_NEW_VM_ROOT_PASS="temporary-password-for-transfer-only"
export PBX_SSH_KEY="$HOME/.ssh/id_ed25519"   # optional
export PBX_SSH_PORT="22"                      # optional

bash scripts/migrate-pbx.sh
```

Without the variables set, the script prompts interactively (no echo on screen). Each person running the script sets their own environment variables — they're never saved anywhere in the repository.

## Bulk migration

If you need to migrate several VMs on the same day (common when the reason for migrating is structural — switching providers or datacenters — not just one isolated customer), running the script sequentially, one at a time, doesn't scale. The simplest approach that works well here is `tmux`, with one window per migration:

```bash
tmux new -s migrations

# inside tmux, one window per VM:
# Ctrl+b c        → create a new window
# Ctrl+b number   → switch between windows (0, 1, 2...)
# Ctrl+b ,        → rename the current window (useful to know which client is which)

# in each window:
export PBX_MYSQL_USER="asteriskuser"
export PBX_MYSQL_PASS="your-password"
# ...remaining variables
bash scripts/migrate-pbx.sh
```

The real benefit of tmux here isn't just running in parallel — it's being able to **close your terminal or drop your SSH connection without killing the migrations in progress**. The tmux session keeps running on the machine where you started it, and you reconnect later with `tmux attach -t migrations` to check progress on each one.

A few things that make a real difference in practice:

- **Don't open too many migrations at once.** Each migration already uses heavy rsync transfers (recordings especially) and simultaneous SSH connections. Opening 15 windows at once saturates your source's outbound bandwidth, and the result is everything running slower instead of faster. Migrating in batches of 3 to 5 tends to be a good balance.
- **Rename tmux windows with the client/VM name**, don't leave them as "1", "2", "3" — when a step asks for manual confirmation (e.g., DNS change), you need to know which window is which quickly, without opening all of them to find out.
- **Log files** (`migration_*.log`) are already timestamped, so running several instances in parallel doesn't cause naming conflicts — but it's worth checking logs between batches instead of only at the end, to catch failures early.
- If a client's recording volume is very large, consider running step 4 (recordings) separately from the rest, in its own window, since it's the step that takes longest and needs the least active attention from you.

## Security

No credential lives in the script. It only exists in memory during execution, coming from environment variables or the interactive prompt.

Details that matter:

- The destination VM's root password is temporary. The script enables `PasswordAuthentication` only during the transfer and reverts it at the end. If the script is interrupted midway, check manually (`grep PasswordAuthentication /etc/ssh/sshd_config`).
- The log never records passwords, only the commands. Still, treat it as sensitive — it exposes table and directory structure.
- Prefer SSH key auth whenever possible. The source VM is the only one that depends on a password (`sshpass`) in this flow, generally because it will be decommissioned shortly after.
- Any password that has already been used in plain text somewhere else (an old script, a chat, a document) should be rotated. No middle ground on this.

## Requirements

- [sshpass](https://sshpass.com/) and [rsync](https://github.com/RsyncProject/rsync)
- SSH key configured for the destination VM (`~/.ssh/id_ed25519` by default)
- `legacy` mode: `issabel_migration.sh` must exist on the destination VM — the script stops if it's not found
- For bulk migration: `tmux` (or `screen`, if you prefer)

## Structure

```
pbx-migration-toolkit/
├── README.md
├── README.pt-br.md
└── scripts/
    └── migrate-pbx.sh
```

## Which mode to choose

If the source is Issabel 4, use `legacy`. If the source is already Issabel 5 but on a build old enough to cause problems with a direct import, use `current`. When in doubt, `legacy` is the more conservative path, and if the native tool doesn't exist on the destination, the script warns and stops instead of proceeding inconsistently.

## Known limitations

- Tested on Issabel over CentOS and Rocky — other distributions may need adjustments to package installation commands
- Assumes local MySQL/MariaDB on both VMs
- `legacy` depends on `issabel_migration.sh` existing on the destination
- External DNS/record change is manual — the script only pauses and waits for confirmation
- Both modes assume the backup was already generated through the panel before running (THE SCRIPT DOES NOT AUTOMATE THIS)

## License

MIT
