# NearDrop — native Windows and Android LAN file sharing

NearDrop is a native Flutter application. It produces a Windows `.exe` and an Android `.apk`; it does not require a browser, cloud account, or shared web server.

## Native flow

1. Install and open NearDrop on both devices while they are on the same private Wi-Fi/LAN.
2. UDP broadcast discovery shows both devices at the same time.
   The **Refresh nearby devices** button sends an immediate discovery request when the list needs updating.
3. Press **Connect** on either device. The other device receives an **Allow / Decline** dialog.
4. After approval, both devices can select files and send them simultaneously in either direction.

Files stream directly between the devices to disk. Completed files are saved directly in each platform's `NearDrop` folder—there are no per-transfer or per-session subfolders. Received filenames are sanitized, partial files are removed on failure, and transfers require a short-lived per-connection capability.

## Source project

The native app is in `neardrop_native/`.
Its Flutter package name is `neardrop`, and its Android application ID is
`com.rhinzler.neardrop`.

```powershell
cd neardrop_native
flutter pub get
flutter test
flutter analyze lib test
```

## Build packages

```powershell
cd neardrop_native
flutter build windows --release
flutter build apk --release
```

Build output locations:

- Windows bundle: `neardrop_native/build/windows/x64/runner/Release/`
- Android package: `neardrop_native/build/app/outputs/flutter-apk/app-release.apk`

Ready-to-share copies:

- `NearDrop-Setup.exe` — Windows installer with Start Menu/uninstall support
- `NearDrop-Windows-x64.zip`
- `NearDrop-Android.apk`

The Windows ZIP must be extracted as a whole; do not copy only the `.exe` because its Flutter DLL and `data` folder are required.

The Windows installer is built with Inno Setup from `neardrop_native/installer/NearDrop.iss`. It installs the complete bundle, creates a Start Menu shortcut, optionally creates a desktop shortcut, and registers an uninstaller.

## Important limitations

- This version uses plain local-network TCP/HTTP transfer. It has approval and capability checks but **does not provide transport encryption or cryptographic peer identity**. Use it only on a trusted private network.
- Wi-Fi guest mode, client isolation, VPNs, and restrictive firewalls can block discovery or transfers.
- Android may pause network activity when the app is backgrounded. Keep the app open during transfers.
- Android receives are written to the user-visible shared-storage folder `/storage/emulated/0/NearDrop` (shown by file managers as `/NearDrop`). On first start, Android 11+ opens NearDrop's **Allow access to manage all files** settings page; grant it, return to NearDrop, and press **Start discovery** again. This special permission is required for a top-level folder outside the app's private directory.
- The Android release is currently signed with the Flutter debug key for local installation. A production Play Store/private-distribution release needs a user-owned signing key.

The earlier browser prototype remains in `client/` and `server/`; it is not required by the native app.
