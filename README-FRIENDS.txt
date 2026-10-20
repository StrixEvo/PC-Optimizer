PC OPTIMIZER - quick guide
==========================

1. Get PCOptimizer.exe only from the Releases page of the repository Flixxs posted.
   Do not use copies from anywhere else.
2. Check it is genuine (30 seconds):
   - Open PowerShell and run:   Get-FileHash "C:\path\to\PCOptimizer.exe" -Algorithm SHA256
   - The long code must match the SHA256 on the Releases page.
   - Inside the app, the "Presets and Log" tab shows the same code for the copy you are running.
3. Run it: double-click PCOptimizer.exe and press Yes on the admin prompt.

USING IT
--------
Simple mode (default): Tune-Up, Dashboard, Gaming, Repair, Presets and Log.
  Tune-Up shows exactly what it will do. Untick anything you want to skip, then press Run.
Advanced mode (switch bottom-left): Services, Startup, Apps, Cleaner, Privacy, Windows Update.
  Dark mode and Advanced mode are remembered.

SAFETY
------
- A restore point is created before bigger changes if System Protection is already on for C:
  (the "Create a restore point" button asks before it switches System Protection on).
- Services, startup entries, gaming tweaks, privacy and update settings are all backed up and can be undone.
- Only apps that came with Windows or your PC are called "junk". Apps you installed yourself are
  listed but never ticked for you. Removed Store apps can be reinstalled from the Microsoft Store.
- This tool never switches off antivirus, the firewall or security updates.
- Everything it changes is listed in the "Presets and Log" tab.
- Windows updates can quietly undo some tweaks. Run the Tune-Up again after big updates.
- If you approve the admin prompt with a different account (for example a parent typing their
  password on a child's PC), the app tells you: per-user changes then apply to the admin account.

ANTIVIRUS WARNING ON THE .EXE
-----------------------------
The .exe is not signed with a paid code-signing certificate, so some antivirus programs may warn
about it. Check the SHA256 above. If it matches, the file is the one that was published.

UPDATES
-------
The app offers updates itself. It only accepts an update signed by the author, and it checks the
download against the signed SHA256 before installing. You always get a Yes/No question first.

PRESETS
-------
Export preset saves your ticked choices to a small file. A friend imports it, reviews the ticks
and presses Apply. Importing never changes anything by itself.

Data and logs are kept in C:\ProgramData\PCOptimizer (only administrators can write there).
