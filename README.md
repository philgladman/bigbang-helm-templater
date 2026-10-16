# Bigbang Helm Templater
Script to fully render a BigBang child service from base and overlay values.

## Overview:
1. Clone and checkout set BigBang version.
2. Extract the target service's base and overlay values.
3. Render the Big Bang umbrella chart to resolve the child service's final values.
4. Identify and clone the child service chart and version defined by Big Bang.
5. Extract the BigBang common, default, and overlay values generated for the service.
6. Render the child chart with those values into a final Kubernetes manifest.

## Run
```bash
## Create service release off main
./bigbang-helm-templater.sh \
  --repo-dir /path/to/k8s \
  --bigbang-tag 3.33.0 \
  --bb-services loki \
  --impact-level il4 \
  --environment sandbox \
  --create-base

## Update values and rerun (without --create-base flag)
./bigbang-helm-templater.sh \
  --repo-dir /path/to/k8s \
  --bigbang-tag 3.33.0 \
  --bb-services loki \
  --impact-level il4 \
  --environment sandbox

## Run diff to compare changes
### Set this to the date directory containing both generated outputs
RUN_DATE=YYYY-MM-DD
git diff --no-index \
  outputs/sandbox-il4/"$RUN_DATE"/services/loki-release-base.yaml \
  outputs/sandbox-il4/"$RUN_DATE"/services/loki-release.yaml
```

## Script Flags/Options
```
--bb-services LIST      Child releases to render, comma-separated, or ALL (required)
--environment ENV       Environment (default: sandbox)
--impact-level LEVEL    Impact level (default: il4)
--bigbang-tag TAG       Big Bang Git tag/ref (default: 3.29.0)
--kube-version VERSION  Target Kubernetes version (default: 1.35.0)
--repo-dir PATH         K8s repository path
--output-dir PATH       Root output directory
--cache-dir PATH        Directory used for cloned repositories
--refresh-repos         Fetch updates in existing repositories
--create-base           Write child outputs as SERVICE-release-base.yaml
-h, --help              Show this help
```
