# sentania-labs/.github

Org-wide GitHub Actions pieces. Anything here is meant to be called from another
repo in the org; nothing here releases anything itself.

## Code signing (macOS, Windows)

Sign and notarize release binaries with the org's identities, so a download from
a GitHub Release runs without Gatekeeper or SmartScreen refusing it. The identities
are held once, as org secrets with visibility "selected repositories". A repo that
wants to sign gets added to each secret's repository list (org settings, Secrets and
variables, Actions, the secret, Repository access); nothing is copied into the repo.

| piece | what it does | runner |
|---|---|---|
| `.github/actions/signing-secrets-present` | fail fast unless all six macOS secrets have a value; run it first, before the build | any |
| `.github/actions/macos-sign` | import the Developer ID certificate into a throwaway keychain, sign with hardened runtime and timestamp, verify strictly, check the team | macOS |
| `.github/actions/macos-notarize` | zip, submit to Apple, wait for Accepted (default 2 h), gatekeeper report, remove the keychain | macOS |
| `.github/actions/windows-sign` | OIDC login to Azure, Authenticode-sign through Azure Artifact Signing, verify | Windows |
| `.github/workflows/notary-diagnostics.yml` | ask Apple about recent submissions and a given id; dispatch here or `workflow_call` | macOS |
| `.github/workflows/signing-selftest.yml` | build a hello binary, sign, notarize (and Windows on request); proves the secrets without a tag | all |

Secrets, all on the org: `MACOS_CERT_P12` (base64 of the .p12), `MACOS_CERT_PASSWORD`,
`MACOS_TEAM_ID`, `NOTARY_ISSUER_ID`, `NOTARY_KEY_ID`, `NOTARY_KEY_P8` (base64 of the .p8)
for macOS; `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_SUBSCRIPTION_ID`,
`ARTIFACT_SIGNING_ENDPOINT`, `ARTIFACT_SIGNING_ACCOUNT`, `ARTIFACT_SIGNING_PROFILE` for
Windows. A composite action cannot read secrets, so the caller passes them as inputs.

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
      - uses: sentania-labs/.github/.github/actions/windows-sign@<sha>
        if: runner.os == 'Windows'   # the job needs permissions: id-token: write
        with:
          files: dist\<binary>.exe
          endpoint: ${{ secrets.ARTIFACT_SIGNING_ENDPOINT }}
          signing-account-name: ${{ secrets.ARTIFACT_SIGNING_ACCOUNT }}
          certificate-profile-name: ${{ secrets.ARTIFACT_SIGNING_PROFILE }}
          azure-tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          azure-client-id: ${{ secrets.AZURE_CLIENT_ID }}
          azure-subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
```

Things worth knowing:

- The macOS ticket is not stapled (a ticket staples only to a bundle), so the
  first run on a Mac asks Apple online. An offline target would need a signed
  .pkg and a Developer ID Installer certificate the org does not hold.
- A release that signs depends on Apple. When notarization is slow the release
  fails and nothing ships, on purpose; rerun the failed jobs against the same
  tag once the diagnostics workflow shows the submission Accepted.
- Apple took 68 to 96 minutes for the org's first submissions (2026-09-15);
  usually it is under a minute.
- The first consumer was vcf-cf-migrator, whose release workflow carried all of
  this inline until 2026-09-30.
