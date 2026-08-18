# Family VPN

Private Android client for one family VPS. The app downloads a JSON profile,
falls back to a cached or bundled profile, checks the tunnel through Xray, and
automatically reconnects through another configured port when health checks
fail.

## Build

1. Install Flutter and the Android SDK.
2. Create `android/key.properties` for the permanent release key.
3. Run `flutter pub get`.
4. Run `flutter build apk --release`.

The current signing key is stored outside the repository at
`C:\Users\baban\.android\family-vpn-release.jks`. Back up the key and
`android/key.properties` securely: losing either prevents future APK updates.

The release APK is generated at `build/app/outputs/flutter-apk/app-release.apk`.

## Runtime

- Profile API: `https://api.kundi.lucartmax.kz/vpn/profile.json`
- VPS: `46.247.42.87`
- VPN ports: `2053`, `8443`, `2083`, `2087`, `2096`
- Port `443` remains reserved for Caddy and other VPS projects.
