# BadooAI
Badoo auto-reply engine using the CapitalAI API. iOS 15–16, Dopamine (rootless).

## Install
1. Grab the `.deb` from Actions artifacts.
2. Install: `dpkg -i com.he.badooai_1.0.1_iphoneos-arm64.deb` (as root)
3. **Restart Badoo** (`killall -9 Badoo`).
4. Check `/var/jb/usr/lib/TweakInject/` has both `BadooAI.dylib` and `BadooAI.plist`.
5. Dopamine app → Badoo → make sure **tweaks are enabled for this app**.

## Config
`/var/mobile/Library/Preferences/com.he.badooai.plist`
Keys: `licenseKey`, `modelId`, `presetId`, `accountId`, `platform`, `modelName`,
`modelAge`, `city`, `enabled`, `dryRun` (set `false` to actually send), plus
`activeFrom/activeTo`, `readDelayMin/Max`, `typingMin/Max`, `contactCooldown`, `pollInterval`.
**After editing the plist run `killall cfprefsd` (as root) or values stay cached.**

## Debug
- On-screen: HUD pill (top-right) shows status, tap = pause/resume; small box under it shows the last log line.
- Syslog: `idevicesyslog | grep BadooAI`
- Log file: app container tmp dir `badoo_ai_debug.log` (Filza → app container), plus attempts `/var/mobile/Documents/badoo_ai_debug.log`.
- No HUD at all? → filter plist missing/mismatched, tweaks disabled for Badoo in Dopamine, or Badoo not restarted. The ctor line `==== BadooAI ctor loaded into <bundle> ====` must appear in syslog; if it doesn't, it's an injection problem, not a logic problem.
