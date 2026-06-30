# TrimMyMac code-signing identity (one-time, manual)

TrimMyMac is signed with a **named self-signed Code Signing certificate** so
that the app's Designated Requirement (identifier + leaf cert) stays **stable
across rebuilds**. This is what lets the Full Disk Access (TCC) grant survive
`scripts/build-app.sh` runs. Ad-hoc signing (`codesign -s -`) bakes the cdhash
into the DR, so every rebuild looks like a brand-new app and FDA is lost.

## Create the identity (Keychain Access — once)

1. Open **Keychain Access**.
2. Menu: **Keychain Access ▸ Certificate Assistant ▸ Create a Certificate…**
3. Name: **TrimMyMac Self-Signed**
   Identity Type: **Self Signed Root**
   Certificate Type: **Code Signing**
   (optionally tick "Let me override defaults" to bump validity to e.g. 3650 days)
4. Click **Create**, accept, **Done**. The cert + private key land in the
   **login** keychain.

## Verify it is visible to codesign

```bash
security find-identity -v -p codesigning
# Expect a line like:
#   1) <40-hex> "TrimMyMac Self-Signed"
```

## Avoid repeated keychain-access prompts (optional, once)

The first `codesign` may prompt "codesign wants to use key ... in your keychain".
Click **Always Allow**. To pre-authorize non-interactively:

```bash
security set-key-partition-list \
    -S apple-tool:,apple: \
    -s -k "<your-login-keychain-password>" \
    ~/Library/Keychains/login.keychain-db
```

## How build-app.sh references it

`scripts/build-app.sh` reads the identity name from `$CODESIGN_IDENTITY`
(default `"TrimMyMac Self-Signed"`) and runs:

```
codesign --force -s "$CODESIGN_IDENTITY" --identifier com.hbh0112.trimmymac <app>
```

Note: **not** `--deep` (it re-signs nested code and is deprecated) and
**not** ad-hoc `-s -`.
