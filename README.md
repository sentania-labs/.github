# sentania-labs/.github

Org-wide GitHub Actions pieces. Anything here is meant to be called from another
repo in the org; nothing here releases anything itself.

## Code signing (macOS, Windows)

Sign and notarize release binaries with the org's identities, so a download from
a GitHub Release runs without Gatekeeper or SmartScreen refusing it. The identities
are held once, as org secrets visible to every repository in the org (2026-10-07,
Scott: per-repo grants were "secret management hell"). A repo that wants to sign
calls the actions below; nothing is copied into the repo and nothing is granted.

| piece | what it does | runner |
|---|---|---|
| `.github/actions/signing-secrets-present` | fail fast unless all six macOS secrets have a value; run it first, before the build | any |
| `.github/actions/macos-sign` | import the Developer ID certificate into a throwaway keychain, sign with hardened runtime and timestamp, verify strictly, check the team | macOS |
| `.github/actions/macos-notarize` | zip, submit to Apple, wait for Accepted (default 2 h), gatekeeper report, remove the keychain | macOS |
| `.github/actions/windows-sign` | Authenticode-sign through Azure Artifact Signing as the org app registration, verify | Windows |
| `.github/actions/attest-provenance` | GitHub artifact attestation (signed build provenance) for the final release files; `gh attestation verify <file> --owner sentania-labs` checks it. Covers Linux, which has no OS signing gate. PUBLIC repos only on the org's Team plan (the action checks and says so) | any |
| `.github/workflows/notary-diagnostics.yml` | ask Apple about recent submissions and a given id; dispatch here or `workflow_call` | macOS |
| `.github/workflows/signing-selftest.yml` | build a hello binary, sign, notarize (and Windows on request); proves the secrets without a tag | all |

Secrets, all on the org: `MACOS_CERT_P12` (base64 of the .p12), `MACOS_CERT_PASSWORD`,
`MACOS_TEAM_ID`, `NOTARY_ISSUER_ID`, `NOTARY_KEY_ID`, `NOTARY_KEY_P8` (base64 of the .p8)
for macOS; `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`,
`ARTIFACT_SIGNING_ENDPOINT`, `ARTIFACT_SIGNING_ACCOUNT`, `ARTIFACT_SIGNING_PROFILE` for
Windows. A composite action cannot read secrets, so the caller passes them as inputs.
The Windows client secret expires 2028-09-29 (app registration "app-signing");
the macOS Developer ID certificate expires 2030. Either expiry fails the release
loudly at the sign step, so keep both dates on the calendar. With all-repos
visibility, any workflow in any org repo can sign; if a secret leaks, rotate it at
the source (the Azure app registration, or Apple) and replace the org secret.

### Onboarding a repo

Nothing to request and nothing to grant: the secrets are already visible to every
repo in the org. In the repo's release workflow (the one that runs on a `vX.Y.Z`
tag):

1. Before the build, call `signing-secrets-present` so a missing secret fails in
   seconds rather than after a 20-minute build.
2. After the binary exists, call `macos-sign` then `macos-notarize` on macOS
   runners and `windows-sign` on Windows runners. Run the repo's own smoke test
   between sign and notarize, on the signed binary, so a signature that breaks
   startup is caught before Apple's round trip.
3. Public repo only: after every file is final (signed where it gets signed),
   call `attest-provenance` once on all of them. The job needs `id-token: write`
   and `attestations: write`. Attest the files that ship, not an earlier copy:
   the attestation is a digest. A private repo skips this step; GitHub sells
   attestations for private repos only with Enterprise Cloud, and the action
   refuses with that message rather than failing upstream after the build.
4. Pin every `uses:` to a commit SHA of this repo, with a comment naming the date,
   and bump the SHA deliberately. Never `@main`.
5. Prove it before the first tag: dispatch `signing-selftest.yml` here (Windows leg
   on) if the org secrets have not been exercised recently, then cut the tag and
   check the release assets with `codesign -dv` / `spctl -a` and
   `Get-AuthenticodeSignature`.
6. Delete any repo-level signing secrets or hand-rolled signing steps the repo
   had before. A repo secret with the same name silently overrides the org one.

Consume by commit SHA, not by branch, from a release workflow:

```yaml
jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@<sha>
      - uses: sentania-labs/.github/.github/actions/signing-secrets-present@<sha>
        with:
          macos-cert-p12: ${{ secrets.MACOS_CERT_P12 }}
          macos-cert-password: ${{ secrets.MACOS_CERT_PASSWORD }}
          macos-team-id: ${{ secrets.MACOS_TEAM_ID }}
          notary-issuer-id: ${{ secrets.NOTARY_ISSUER_ID }}
          notary-key-id: ${{ secrets.NOTARY_KEY_ID }}
          notary-key-p8: ${{ secrets.NOTARY_KEY_P8 }}

  binaries:
    permissions:
      contents: read
      id-token: write        # attest-provenance
      attestations: write    # attest-provenance
    # ... build dist/<binary> on a macOS runner, then:
      - uses: sentania-labs/.github/.github/actions/macos-sign@<sha>
        if: runner.os == 'macOS'
        with:
          binary: dist/<binary>
          # entitlements: packaging/my.plist   (default: disable library validation only)
          macos-cert-p12: ${{ secrets.MACOS_CERT_P12 }}
          macos-cert-password: ${{ secrets.MACOS_CERT_PASSWORD }}
          macos-team-id: ${{ secrets.MACOS_TEAM_ID }}
      # your own smoke test of the signed binary goes here
      - uses: sentania-labs/.github/.github/actions/macos-notarize@<sha>
        if: runner.os == 'macOS'
        with:
          binary: dist/<binary>
          notary-issuer-id: ${{ secrets.NOTARY_ISSUER_ID }}
          notary-key-id: ${{ secrets.NOTARY_KEY_ID }}
          notary-key-p8: ${{ secrets.NOTARY_KEY_P8 }}
      # If a step of yours between sign and notarize can fail, remove the
      # keychain yourself; only matters on a self-hosted Mac (hosted runners
      # are discarded). macos-sign and macos-notarize clean up their own failures.
      - if: always() && runner.os == 'macOS'
        run: security delete-keychain "${KEYCHAIN:-$RUNNER_TEMP/signing.keychain-db}" 2>/dev/null || true
      - uses: sentania-labs/.github/.github/actions/windows-sign@<sha>
        if: runner.os == 'Windows'
        with:
          files: ${{ github.workspace }}\dist\<binary>.exe   # absolute paths
          endpoint: ${{ secrets.ARTIFACT_SIGNING_ENDPOINT }}
          signing-account-name: ${{ secrets.ARTIFACT_SIGNING_ACCOUNT }}
          certificate-profile-name: ${{ secrets.ARTIFACT_SIGNING_PROFILE }}
          azure-tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          azure-client-id: ${{ secrets.AZURE_CLIENT_ID }}
          azure-client-secret: ${{ secrets.AZURE_CLIENT_SECRET }}
      # Last, once nothing else will change the files. Public repo only;
      # needs the two permissions on the job above.
      - uses: sentania-labs/.github/.github/actions/attest-provenance@<sha>
        with:
          subject-path: dist/*
```

### macOS bundle mode (.app)

`macos-sign` and `macos-notarize` each take `bundle:` (a `.app` path) instead of
`binary:`; pass exactly one. The bare-binary path is unchanged.

- `macos-sign bundle:` signs every nested Mach-O, `.framework`, `.xpc` and inner
  `.app` under `Contents/`, deepest first, with hardened runtime and timestamp
  (never `--deep` for signing), then signs the bundle with the entitlements
  (default: disable-library-validation; override with `entitlements:`). It then
  runs `codesign --verify --deep --strict`, and checks the runtime flag and team.
  The app's `CFBundleExecutable` must exist under `Contents/MacOS/`.
- `macos-notarize bundle:` zips with `ditto -c -k --keepParent`, submits, and on
  Accepted runs `stapler staple` and `stapler validate`, then hard-gates on
  `codesign --verify --deep --strict`, `spctl -a -t exec -vv` and
  `--test-requirement="=notarized"`. It then rebuilds the release zip from the
  stapled app at `output-zip` (default `<bundle>.zip`) and returns it as output
  `zip`. Upload that zip, never the submission zip.
- Run the caller's smoke test between sign and notarize against
  `<bundle>/Contents/MacOS/<exe>`.

```yaml
      - uses: sentania-labs/.github/.github/actions/macos-sign@<sha>
        with:
          bundle: dist/My App.app
          macos-cert-p12: ${{ secrets.MACOS_CERT_P12 }}
          macos-cert-password: ${{ secrets.MACOS_CERT_PASSWORD }}
          macos-team-id: ${{ secrets.MACOS_TEAM_ID }}
      - id: notarize
        uses: sentania-labs/.github/.github/actions/macos-notarize@<sha>
        with:
          bundle: dist/My App.app
          output-zip: dist/My-App-macos-arm64.zip
          notary-issuer-id: ${{ secrets.NOTARY_ISSUER_ID }}
          notary-key-id: ${{ secrets.NOTARY_KEY_ID }}
          notary-key-p8: ${{ secrets.NOTARY_KEY_P8 }}
      # release asset: ${{ steps.notarize.outputs.zip }}
```

Things worth knowing:

- A bare-binary macOS ticket is not stapled (a ticket staples only to a bundle), so
  the first run on a Mac asks Apple online. Ship a `.app` and use bundle mode to
  get a stapled, offline-verifiable result (next section).
- A release that signs depends on Apple. When notarization is slow the release
  fails and nothing ships, on purpose; rerun the failed jobs against the same
  tag once the diagnostics workflow shows the submission Accepted.
- Apple took 68 to 96 minutes for the org's first submissions (2026-09-15);
  usually it is under a minute.
- The first consumer was vcf-cf-migrator, whose release workflow carried all of
  this inline until 2026-09-30.
