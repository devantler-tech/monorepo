# Desktop app updates

A Bash script and small Go/AppKit helper maintain the ChatGPT and Claude desktop
apps through their official Homebrew casks. No AI workflow or model usage is involved.
Command-line tools and plugins are outside its scope.

## Install and run

Requires macOS with a logged-in desktop user, Homebrew, jq, Go, and the Xcode
command-line tools. Both apps must already be registered with Homebrew as
`chatgpt` and `claude`. The former installs `/Applications/ChatGPT.app` with bundle
ID `com.openai.codex`; the deprecated `codex-app` and the `codex` CLI are excluded.
Alternate application paths, release channels and bundle IDs fail closed.

```sh
bash tools/desktop-app-updates/validate.sh
bash tools/desktop-app-updates/install.sh --schedule
~/bin/update-agent-desktops --check
~/bin/update-agent-desktops --apply
tail -n 30 ~/Library/Logs/DesktopAppUpdates.log
```

Installation copies a source snapshot into a private, immutable release directory
under `~/.local/libexec/desktop-app-updates/`. A manifest records its source digest
and Git revision. Previous releases remain available. Reinstall after pulling a
reviewed change; the scheduled job never fetches or executes repository source.
Use `--no-schedule` to install without changing launchd. Scheduling is opt-in and
runs hourly; loading the job does not immediately restart applications.

## Update and recovery behavior

1. Refresh Homebrew and compare actual bundle versions with the available casks.
2. Download and verify the package before closing anything.
3. Save a private version/restart snapshot and request a normal macOS quit.
4. Wait for the application and its helper processes to exit. Never force quit.
5. Update only that desktop cask and verify its installed identity and version.
6. Reopen the application in the background if it was previously running.

Homebrew pins are respected. A newer native version is never replaced by an
older cask. An adopted app whose receipt is newer than its actual bundle is
repaired by a closed-app reinstall. Automatic updating preferences and application
data remain untouched. No `--zap`, forced termination, UI scripting, private app
endpoints, or synthetic chat continuations are used.

A native save/quit confirmation, refusal, timeout, or remaining process defers
the update. The per-app pending record is retained: later checks do not send
repeated quit requests. Complete the native quit when work is saved and ready;
the next hourly run finishes the queued update and restores the client, even if
that quit happened after the original timeout. The other app can still update independently. Failed updates
also attempt normal restoration; a failed reopen is retried before network work.

App reopening relies on the application's own saved-state/session restoration.
The receipt explicitly says `sessionRestoration: native_unverified`. A reopened
process does not prove that agent work continued. The script cannot guarantee
unattended updates while an app requires user confirmation, nor can it guarantee
native session continuation. It never restarts individual chats.

State and snapshots are private, outside Git, under
`~/Library/Application Support/DesktopAppUpdates/`. Each app has a separate pending
restart journal and last-recovery receipt. An isolated cache under
`~/Library/Caches/DesktopAppUpdates/Homebrew/` avoids launchd restrictions on a
normal cache located on an external volume; existing cache symlinks are preserved.

To stop the hourly schedule without uninstalling anything:

```sh
launchctl bootout gui/$(id -u)/tech.devantler.desktop-app-updates
```

## Verification

`validate.sh` runs ShellCheck, fixture-driven update/recovery scenarios for both
casks, Go validation, repeatable installation in a temporary home, and a real
macOS lifecycle test. The latter launches a disposable AppKit application and
verifies quit refusal, path validation, process exit, and reopening with a new PID.
It never closes either real client. Actual app update attempts must be checked
separately; passing the canary does not establish native chat recovery.

References: [Homebrew commands](https://docs.brew.sh/Manpage),
[ChatGPT cask](https://formulae.brew.sh/cask/chatgpt),
[Claude cask](https://formulae.brew.sh/cask/claude),
[normal macOS quit API](https://developer.apple.com/documentation/appkit/nsrunningapplication/terminate()).
