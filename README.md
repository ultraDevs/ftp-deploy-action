# lftp FTP/FTPS Deploy

A GitHub Action that deploys a directory to an FTP or FTPS server using [lftp](https://lftp.yar.ru/), with git-diff-based incremental uploads and verbose, actually-debuggable output.

Built by [ultraDevs](https://ultradevs.com) after burning an afternoon on cryptic `530 Login authentication failed` errors from another FTP action — this one prints the real lftp protocol exchange so you can see exactly what the server said.

## Why this instead of other FTP actions

- **Real error messages.** lftp's output shows the actual FTP/FTPS command-response exchange, not a wrapped stack trace.
- **Incremental by default.** On a normal `push` event, it diffs `github.event.before` against `github.sha` and uploads/deletes only the files that changed — no full-tree re-scan every run. Falls back to a full mirror automatically when there's nothing to diff against (first run, non-`push` events, force-pushes).
- **No proprietary state file.** Incremental mode uses git history you already have, not a JSON file it has to read back from the server first.

## Usage

```yaml
- name: Deploy over FTPS
  uses: ultraDevs/ftp-deploy-action@v1
  with:
    server: ftp.example.com
    username: ${{ secrets.FTP_USER }}
    password: ${{ secrets.FTP_PASSWORD }}
    remote-dir: /public_html/
    exclude: |
      .git
      .github
      node_modules
      src
      *.log
```

**Important:** for incremental deploys to work, `actions/checkout` needs enough history to see the commit before this push:

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0   # or a small fixed depth if the repo is huge
```

Without this, the action logs why it couldn't diff and safely falls back to a full mirror instead of failing.

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `server` | yes | | FTP server hostname |
| `username` | yes | | FTP username |
| `password` | yes | | FTP password |
| `port` | no | `21` | FTP port |
| `protocol` | no | `ftps` | `ftp` (no encryption) or `ftps` (explicit TLS) |
| `ssl-verify` | no | `true` | Set to `false` to skip TLS certificate hostname/CA validation — needed when the FTP hostname is an alias and the server's cert only covers its real hostname (common on shared cPanel hosting) |
| `local-dir` | no | `.` | Local directory to deploy from |
| `remote-dir` | yes | | Absolute remote directory to deploy to |
| `exclude` | no | `.git`, `.github` | Newline-separated paths/globs to exclude |
| `full-deploy` | no | `false` | Force a full mirror instead of incremental |
| `dry-run` | no | `false` | Print what would happen without connecting |

## Outputs

| Output | Description |
|---|---|
| `mode` | `full` or `incremental` |
| `uploaded-count` | Files uploaded (incremental mode only) |
| `deleted-count` | Files deleted (incremental mode only) |

## Certificate hostname mismatch

If you see something like:

```
SSL: no alternative certificate subject name matches target host name 'ftp.example.com'
```

your FTP hostname is a CNAME/alias pointing at a server whose TLS certificate was issued for its own hostname, not yours — common on cPanel resharing hosting where `ftp.yourdomain.com` and the box's real hostname resolve to the same IP but only the real hostname is in the cert's SAN list. Set `ssl-verify: false` to accept the connection anyway (this is what most desktop FTP clients do silently when you click through a certificate warning).

## License

MIT
