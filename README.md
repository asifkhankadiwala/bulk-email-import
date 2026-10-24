# imapsync-bulk

Bulk mailbox migration with [imapsync](https://imapsync.lamiral.info/): read accounts from a CSV, sync each mailbox from a **source IMAP** host to a **destination IMAP** host.

Designed for long overnight runs: retries on transient failures, **skips authentication failures**, and prints a summary of which addresses failed login.

## Requirements

- macOS or Linux
- [imapsync](https://imapsync.lamiral.info/) installed and on your `PATH`

```bash
# macOS (Homebrew)
brew install imapsync
```

## Quick start

```bash
git clone <your-repo-url> imapsync-bulk
cd imapsync-bulk

cp accounts.example.csv accounts.csv
# Edit accounts.csv — one row per mailbox (real passwords stay local; file is gitignored)

# Optional: override hosts (defaults are set in the script / env)
export HOST1=old.mail.example.com     # source (old server)
export HOST2=new.mail.example.com     # destination (new server)

chmod +x imapsync-auto.sh
./imapsync-auto.sh
```

### Long runs (recommended)

Keep the Mac awake and survive terminal disconnects:

```bash
tmux new -s mail-migrate
caffeinate -dims ./imapsync-auto.sh
# Detach: Ctrl+b then d
# Reattach later: tmux attach -t mail-migrate
```

If you already started the script without `caffeinate`:

```bash
# Use -n so only one PID is passed (multiple matches break caffeinate -w)
caffeinate -dims -w "$(pgrep -n -f 'imapsync-auto.sh')"
```

## CSV format

`accounts.csv` (copy from `accounts.example.csv`):

| Column | Meaning |
|--------|---------|
| `email` | Mailbox address (same on host1 and host2) |
| `password_old` | Password on **source** (`HOST1`) |
| `password_new` | Password on **destination** (`HOST2`) |

```csv
email,password_old,password_new
info@example.com,OldPassHere,NewPassHere
```

- Rows with an empty password are skipped.
- Do **not** commit `accounts.csv` — it is listed in `.gitignore`.

## Configuration

| Variable | Default | Purpose |
|----------|---------|---------|
| `HOST1` | *(required)* | Source IMAP host |
| `HOST2` | *(required)* | Destination IMAP host |
| `CSV_FILE` | `./accounts.csv` (next to the script) | Path to accounts CSV |
| `WORKDIR` | script directory | Temp pass files + logs |
| `RETRY_SLEEP` | `60` | Seconds between retries on non-auth failures |

Example:

```bash
HOST1=old.mail.example.com HOST2=new.mail.example.com ./imapsync-auto.sh
```

## Behavior

| Situation | Action |
|-----------|--------|
| Sync succeeds | Log `DONE`, next account |
| Auth failure (`AUTHENTICATIONFAILED`, bad password, etc.) | **Skip** account, record it, continue |
| Other failure (killed, network, etc.) | Retry forever after `RETRY_SLEEP` |
| Empty password in CSV | Skip row |

At the end the script prints an **AUTHENTICATION FAILURES** list and writes:

- `sync-all.log` — full run log (next to the script)  
- `auth-failures.log` — auth skips only  

Exit codes:

- `0` — finished with no auth skips  
- `1` — missing CSV / imapsync not installed  
- `2` — finished but one or more accounts failed authentication  

## Manual single-account test

Useful before a bulk run:

```bash
imapsync \
  --host1 "$HOST1" --user1 user@example.com --passfile1 ./pass1.txt --ssl1 \
  --host2 "$HOST2" --user2 user@example.com --passfile2 ./pass2.txt --ssl2
```

Create pass files with one password per line and `chmod 600` them. Never put passwords on the command line in shared history if you can avoid it.

## Security notes

- Keep `accounts.csv` only on your machine; never push it to GitHub.
- Temp password files in the script directory are mode `600` and removed when the script finishes cleanly.
- Prefer running in `tmux` on a locked machine for multi-hour migrations.

## License

Use and modify freely for your own migrations.
