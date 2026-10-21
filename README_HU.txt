NOVA Hi-Fi Remote - Codemagic project (Windows-friendly source package)

WHAT THIS IS
This is a native SwiftUI iOS app source project prepared for Codemagic.
It is not yet a signed/installable IPA.

FILES
- ContentView.swift: iPhone UI, Wi-Fi HTTP controls, BLE controls
- Info.plist: iOS permission strings
- project.yml: XcodeGen project definition
- codemagic.yaml: cloud build recipe
- README_HU.txt: original notes

NEXT STEPS
1. Create a GitHub repository, e.g. NOVA-HiFi-Remote.
2. Upload ALL files in this folder to the repository root. Do not upload the ZIP as a single file.
   On GitHub: Add file -> Upload files -> drag the files, then Commit changes.
3. In Codemagic, choose Add application, connect GitHub, and select this repository.
4. Choose the codemagic.yaml workflow / YAML configuration and start a build.
5. Download NOVAHiFiRemote-unsigned.ipa from build artifacts if the build succeeds.
6. Try importing the IPA into Sideloadly. Sideloadly must sign it with an Apple ID before installation; signing and free-account provisioning limitations may apply.

IMPORTANT
- This workflow produces an unsigned IPA package, intended for later signing with Sideloadly. It is not App Store-ready.
- If Codemagic's current plan/runner does not permit the selected macOS instance or YAML workflow, choose an available macOS runner in the UI.
- The app bundle identifier is hu.novahifi.remote. If you later change it, update project.yml.
- Wi-Fi controls expect ESP32 endpoints GET /api/state and GET /api/cmd?c=COMMAND.
- BLE expects device name HiFi-ESP32 and the UUIDs documented in ContentView.swift.
- ESP32 firmware must be configured with the home Wi-Fi SSID/password. The iPhone and ESP32 must be on the same LAN for Wi-Fi control.
- UI commands are control prototypes. They do not yet implement real audio routing/DSP in the ESP32 firmware.
