# GitHub Actions integration

Publish zwanzig results to GitHub code scanning to see issues in pull requests.

## 1. Add the required permission to your workflow

```yaml
permissions:
  contents: read
  security-events: write  # Required for uploading SARIF
```

## 2. Add steps to run zwanzig and upload results

```yaml
- name: Run zwanzig analysis
  run: |
    zwanzig --format sarif src/ > results.sarif || true

- name: Upload SARIF results
  uses: github/codeql-action/upload-sarif@v3
  with:
    sarif_file: results.sarif
```

The `|| true` ensures the workflow continues even if zwanzig finds issues, so results are always uploaded.

## 3. Optional: run on every push, even if other steps fail

```yaml
- name: Run zwanzig analysis
  if: always()
  run: |
    zwanzig --format sarif src/ > results.sarif || true

- name: Upload SARIF results
  if: always()
  uses: github/codeql-action/upload-sarif@v3
  with:
    sarif_file: results.sarif
```

Results appear in:

- Security tab > Code scanning alerts
- Pull requests > Checks > Code scanning results
- Inline annotations on changed files
