# ToneVault

iOS AUv3 neural amp modeler (NAM) with a built-in TONE3000 browser.

- **ToneVault app**: sign in to TONE3000, search, download `.nam` captures.
- **ToneVault AUv3 plugin**: load in GarageBand, AUM, Loopy Pro, etc. Input, gate, 3-band EQ, output.
- Models are shared through an App Group. If your sideloader strips it, the plugin's **Import…** button
  loads `.nam` files straight from Files.

## First-time setup
```bash
git init && git add -A
git submodule add https://github.com/sdatkinson/NeuralAmpModelerCore.git Vendor/NeuralAmpModelerCore
git submodule update --init --recursive      # pulls Eigen + json
./setup.sh com.yourname                      # your bundle prefix / app group
git commit -am "Initial commit"
gh repo create tonevault --private --source=. --push   # or create on github.com and `git push`
```
Open the **Actions** tab, wait for *Build IPA*, download the **ToneVault-ipa** artifact, unzip, and sideload
`ToneVault.ipa` (AltStore / Sideloadly / TrollStore). Publishing a GitHub Release also attaches the IPA.

## TONE3000
1. tone3000.com › Settings › API Keys › create a key (`t3k_pub_…`).
2. Add redirect URI `tonevault://callback`.
3. App › Account › paste key › Sign in.
If custom-scheme redirects are rejected, paste an access token under *Fallback*.

## Local build
`brew install xcodegen && xcodegen generate && open ToneVault.xcodeproj`
