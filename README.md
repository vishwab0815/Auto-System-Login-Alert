# Windows Login Email Alert (Resend)

One PowerShell file that emails you when your Windows PC is:
- **logged on / unlocked** (success), and
- hit with a **wrong password / failed unlock** (failure, Security event 4625).

Personal security tripwire for your own machine, using the [Resend](https://resend.com) HTTPS API.

## Single file

Everything lives in **`WinLoginAlert.ps1`**. Switches select what it does:

| Command | Does |
|---------|------|
| `-Install` | Deploys itself to `C:\ProgramData\WinLoginAlert\`, locks permissions, enables failure auditing, registers both scheduled tasks, sends a test |
| `-Uninstall` | Removes both scheduled tasks |
| `-Mode Success` / `-Mode Failed` | Sends one alert (the tasks call it this way; you don't need to) |

Config (API key + recipient) is set at the top of the script:

```powershell
$RESEND_API_KEY = 're_...'
$ALERT_EMAIL    = 'you@example.com'
```

## Install

Open **PowerShell as Administrator**, `cd` to this folder, then:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\WinLoginAlert.ps1" -Install
```

That one command deploys, secures, enables auditing, registers the two tasks, and fires a test email.

## Verify

```powershell
Get-ScheduledTask -TaskName "Windows Login Email Alert (Resend)"   # success task
Get-ScheduledTask -TaskName "Windows Login FAIL Alert (Resend)"    # failed-attempt task
```

- **Success test:** `Win + L` then unlock → you get an email.
- **Failure test:** `Win + L`, type a wrong password once, then unlock properly → you get a "failed attempt" email.

Logs/throttle state are written to `%LOCALAPPDATA%\WinLoginAlert\` (the install folder is
read-only for standard users). If something fails, check
`%LOCALAPPDATA%\WinLoginAlert\last_error.log`.

## How it works

| Piece | Detail |
|-------|--------|
| Success task | Triggers `AtLogOn` + session-unlock (`StateChange=8`); runs as the **logged-on user** so the username/Wi-Fi are correct |
| Failed task | Triggers on **Security event 4625**; runs as **SYSTEM** (no user at the lock screen); reads the attempted account from the event; only alerts on interactive/unlock/RDP failures |
| Throttle | One email per 120s per kind, so repeats don't flood you |
| Reliability | TLS 1.2 forced, waits up to 30s for network at logon, `User-Agent` header set, values HTML-encoded |

## Uninstall

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\WinLoginAlert.ps1" -Uninstall
# Remove everything, including the deployed copy:
Remove-Item "C:\ProgramData\WinLoginAlert" -Recurse -Force   # (Admin)
```

## Notes

- **Resend test sender:** `onboarding@resend.dev` only delivers to your Resend account
  email. To send elsewhere, verify your own domain and change the `from` line.
- **Failure alerts need auditing:** the installer runs
  `auditpol /set /subcategory:"Logon" /failure:enable`. Uninstall leaves it on.
- **Security:** the API key is stored in plaintext inside the script. It's readable by
  any local user who can run it — acceptable on a trusted personal PC; don't share the
  file or commit it with a real key.
