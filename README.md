# PC Optimizer

A Windows tune-up tool: clean temp files, switch off pointless services and startup apps, remove
preinstalled junk, boost gaming performance, repair Windows, and tighten privacy.
Every change is backed up and can be undone.

## Get it
Download **`PCOptimizer.exe`** from the [latest release](../../releases/latest) and double-click it.
Press Yes on the admin prompt.

The exe is not code-signed with a paid certificate, so Windows SmartScreen or your antivirus may warn.
Check your download against the SHA256 printed on the release page:

    Get-FileHash .\PCOptimizer.exe -Algorithm SHA256

The same value is shown in the app on the **Presets and Log** tab.

## Language
The app is in English and Welsh (Cymraeg). Use the button at the bottom of the sidebar to switch; the choice is
remembered, and a Windows set to Welsh starts the app in Welsh. The Welsh is a draft: menus, buttons, headings and the
main messages are translated, using Welsh Government TermCymru terms where it has an entry. Descriptions of individual
services and tweaks, and messages with numbers in them, are still English. Corrections from Welsh speakers are welcome.

## Updates
The app checks this repository a few seconds after it starts and offers an update. It installs
nothing unless you press Yes, and it only accepts an update whose `version.json` carries a signature
made with the author's private release key (the matching public key is built into the app). Someone
who gains write access to this repository can change `version.json`, but cannot produce that
signature, so the app ignores their update. The download is then also checked against the signed
SHA256 before it replaces anything.

Copies of version 2.1 or older came from a different repository and do not update from here.
Download 2.2 once; it updates itself from then on.

## Source
`PCOptimizer.ps1` is the whole program, readable here. The exe is built from it with
[ps2exe](https://github.com/MScholtes/PS2EXE) (`Build-PCOptimizer-Exe.bat`). A ps2exe exe embeds the
script, so the exe can be unpacked: the protection against tampering is the signed update check
above, not secrecy.

## Publishing a release (author)
1. Raise `$script:AppVersion` in `PCOptimizer.ps1`.
2. Double-click `Publish-Update.bat` and type what changed. It builds the exe, signs `version.json`
   with `%USERPROFILE%\pcoptimizer-signing-key.xml`, creates the GitHub release with the exe, then pushes.

Keep the signing key private and backed up. If it is lost, no further update can be signed.

See `README-FRIENDS.txt` for a plain-English guide.
