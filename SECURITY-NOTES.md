# Security notes

A cursory review of this fork, not a full audit. No line-by-line reading of all
~7,700 lines of `trans.sh` and ~5,000 of `reinstall.sh`; the focus was on how
code and data enter the machine, how credentials are handled, and what talks to
the network.

**Nothing malicious was found.** No telemetry, no beaconing, no exfiltration of
host data. The findings below are design weaknesses inherent to what this tool
does — it downloads an OS and overwrites your disk — not signs of foul play.

Keep in mind what the tool *is*: it runs as root, wipes the main disk, and
chain-loads an installer. That is unavoidably destructive. The question is not
whether it can destroy the system (it must) but whether the code that does so
can be influenced by someone other than you.

## Findings

### 1. TLS verification is disabled globally — highest impact

`reinstall.sh` wraps `curl` in a function that always passes `--insecure`:

- `reinstall.sh:169-180` — the `curl()` wrapper, used for *every* download
- `reinstall.sh:370` — the range-request probe
- `reinstall.bat:186` — the same for the Windows bootstrap
- `trans.sh:7091` — `wget --no-check-certificate` for the HTTP time sync

Certificate validation is off for every fetch: `trans.sh`, kernels, initrds,
cloud images, Windows ISOs. The upstream rationale is in the comments — 32-bit
cygwin ships stale roots, and ARM initramfs boots with a wrong clock, both of
which break certificate validation. Real problems, but the fix is applied
globally rather than to the affected paths.

Combined with finding 2, anyone who can intercept your traffic (a hostile
network, a compromised upstream router, BGP/DNS hijack) can substitute the code
that installs your OS. Not remotely exploitable by an unprivileged attacker —
it requires a network position.

### 2. Remote code is executed with no integrity check

`reinstall.sh` downloads 28 files from `$confhome` at run time and executes
them. There are no checksums and no signatures anywhere in the codebase.

- `trans.sh` — 292KB, the bulk of the real logic, downloaded into the initrd
  (`reinstall.sh:3877`)
- `. <(curl -L $confhome/windows-driver-utils.sh)` — sourced directly
  (`reinstall.sh:3923`, also `trans.sh:3423` and `trans.sh:5425`)
- `curl -L $confhome/ttys.sh | sh` — piped to a shell (`reinstall.sh:3169`)

The only trust anchor is "whoever controls the `confhome` host, plus TLS" — and
TLS is disabled per finding 1.

**This is why `confhome` was repointed at your own repository.** A fork that
leaves it pointing upstream still executes upstream's code at run time no matter
what the local copy says. `--confhome` was added so the files can be served from
a host you control (see the README).

### 3. Third-party ISO link brokers

Windows ISO URLs are obtained from services that are not Microsoft:

- `delivery-api.ntriver.org/generate-link` (`reinstall.sh:1584`)
- `fnnas.com/asset/download-sign` — removed with the fnos target

These return an arbitrary URL which is then downloaded and installed. Nothing
verifies the ISO afterwards. If you care about ISO provenance, pass `--iso` with
a URL you trust rather than relying on automatic lookup.

### 4. Unauthenticated log viewer during installation

The install log is served over HTTP on `--web-port` with no authentication, and
SSH is exposed on `--ssh-port`, for the duration of the install.

Partly mitigated: the streamed log filters lines containing `password` or `token`
(`trans.sh:418`), and passwords are stripped from `autounattend.xml` before it is
displayed (`trans.sh:6907`). Still, anyone who can reach the box during the
install window can read the progress log.

### 5. Cloud-vendor drivers retained

`add_driver_aliyun_virtio` and `add_driver_qcloud_virtio` download drivers from
`aliyuncs.com` and `mirrors.tencent.com`. These were **kept deliberately**: they
are vendor drivers gated on `$vendor` actually being `aliyun`/`qcloud`
(`trans.sh:5815-5817`), so they never fire on a US/EU provider. They are not mirrors,
and removing them would break Windows installs on those clouds. Delete them if
you will never use those providers.

## What looks fine

- **Password handling.** Passwords are hashed with SHA-512 before being written
  to the target (`get_password_linux_sha512`). The code comments show deliberate
  thought about plaintext leaking via `/reinstall.log` and shell history.
- **Disk targeting.** The main disk is identified by partition-table ID and
  re-verified, with an explicit guard against a bogus value causing every disk to
  be formatted (`get-xda.sh`).
- **No telemetry.** No outbound POSTs of host data. The only POST is a signed
  download request for an ISO.
- **The geo-IP callout is gone.** Upstream contacted `www.qualcomm.cn/cdn-cgi/trace`
  on *every* run and aborted when unreachable. Removed in this fork — both a
  privacy and a reliability improvement.

## Recommendations

1. **Serve `confhome` from a host you control**, and prefer `--confhome` over the
   `raw.githubusercontent.com` default when the repository is private.
2. **Consider re-enabling TLS verification.** Dropping `--insecure` from the
   `curl()` wrapper at `reinstall.sh:180` is a one-line change. It may break
   32-bit cygwin and some ARM initramfs boots; test on your hardware.
3. **Pin `--iso` explicitly** for Windows rather than trusting automatic lookup.
4. **Treat the install window as exposed.** Use `--web-port`/`--ssh-port` on a
   restricted network, or firewall them.
5. **Verify on a disposable host first.** `--debug` only dry-runs URL and mirror
   resolution; it does not exercise `trans.sh` on the target.

## Licensing

This is a fork of [bin456789/reinstall](https://github.com/bin456789/reinstall),
GPL-3.0. `LICENSE` is unmodified and attribution is retained in the README.

GPL obligations attach on **distribution**, not use — a private repository for
your own machines triggers none of them. If you ever publish or hand this to
someone else, you must offer the source under GPL-3.0 and keep the attribution.
