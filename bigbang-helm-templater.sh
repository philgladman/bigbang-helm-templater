#!/usr/bin/env bash
set -euo pipefail

# Big Bang Helm Templater
#
# Renders a Big Bang umbrella chart using all ConfigMap-embedded values from a
# Kubernetes repository's base/core-configs directory, followed by the selected
# environment overlay. It can then render one, several, or all enabled child
# Helm releases into separate files for inspection and comparison.
#
# Use --create-base before changing values to save SERVICE-release-base.yaml;
# rerun without it afterward to create SERVICE-release.yaml for a clean diff.
# Outputs are grouped by environment, impact level, and date under output_root.
#
# Current scope: Secret-backed values, ExternalSecrets, Flux valuesFrom ordering,
# Kustomize patches, and Helm post-renderers are intentionally not resolved.
# Required commands: git, helm, and yq v4.

# Resolve this script's directory so its defaults work from any current directory.
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Set default chart versions, repository locations, and command-line state.
bigbang_tag="3.29.0"
kube_version="1.35.0"
k8s_repo_dir="$HOME/k8s"
k8s_env="sandbox"
k8s_impact_level="il4"
output_root="${script_dir}/outputs"
cache_dir="${script_dir}/repos"
bigbang_repo_url="https://repo1.dso.mil/big-bang/bigbang.git"
bb_services_csv=""
refresh_repos=false
create_base_release=false
render_all_services=false

# Display command syntax, options, examples, and the renderer's current limits.
usage() {
  cat <<'EOF'
Usage:
  bigbang-helm-templater.sh --bb-services SERVICE[,SERVICE...] [options]

Required:
  --bb-services LIST       Child releases to render, comma-separated, or ALL

Options:
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

Examples:
  ./bigbang-helm-templater.sh --bb-services grafana
  ./bigbang-helm-templater.sh --bb-services loki --create-base
  ./bigbang-helm-templater.sh --bb-services istio-gateway,monitoring,grafana
  ./bigbang-helm-templater.sh --bb-services ALL

This script intentionally ignores HelmRelease valuesFrom ordering, Secret-backed values,
Kustomize patches, and ExternalSecret resolution. Every values.yaml embedded in
base/core-configs is merged first; the complete environment overlay is applied
second.
EOF
}

# Print a fatal error and stop the script with a nonzero exit status.
die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

# Print a progress or result message to standard output.
log() {
  printf '%s\n' "$*"
}

# Add a successfully rendered child release and its output path to the summary.
record_rendered_service() {
  printf '\n- Service: %s\n  Status: rendered\n  Output: %s\n' \
    "$1" "$2" >> "$summary_file"
}

# Add a failed child release and a short explanation to the summary.
record_failed_service() {
  printf '\n- Service: %s\n  Status: failed\n  Reason: %s\n' \
    "$1" "$2" >> "$summary_file"
}

# Ensure an option that needs a following argument actually received one.
require_value() {
  [[ $# -ge 2 && -n "$2" ]] || die "$1 requires a value"
}

# Read command-line options and replace defaults with values supplied by the user.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bb-services)
      require_value "$1" "${2:-}"
      bb_services_csv="$2"
      shift 2
      ;;
    --environment)
      require_value "$1" "${2:-}"
      k8s_env="$2"
      shift 2
      ;;
    --impact-level)
      require_value "$1" "${2:-}"
      k8s_impact_level="$2"
      shift 2
      ;;
    --bigbang-tag)
      require_value "$1" "${2:-}"
      bigbang_tag="$2"
      shift 2
      ;;
    --kube-version)
      require_value "$1" "${2:-}"
      kube_version="$2"
      shift 2
      ;;
    --repo-dir)
      require_value "$1" "${2:-}"
      k8s_repo_dir="$2"
      shift 2
      ;;
    --output-dir)
      require_value "$1" "${2:-}"
      output_root="$2"
      shift 2
      ;;
    --cache-dir)
      require_value "$1" "${2:-}"
      cache_dir="$2"
      shift 2
      ;;
    --refresh-repos)
      refresh_repos=true
      shift
      ;;
    --create-base)
      create_base_release=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1 (use --help)"
      ;;
  esac
done

# Require an explicit child-service selection so the render scope is intentional.
[[ -n "$bb_services_csv" ]] || die "--bb-services is required"

# Fail early when a command needed by the rendering workflow is unavailable.
for tool in git helm yq; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed or not in PATH"
done

# Build the base and overlay input paths from the selected repository/environment.
core_configs_dir="${k8s_repo_dir}/deploy/bigbang/base/core-configs"
overlay_values="${k8s_repo_dir}/deploy/bigbang/overlays-ugc/${k8s_env}/${k8s_impact_level}/bigbang.values.yaml"

# Verify both required configuration locations exist before doing any rendering.
[[ -d "$core_configs_dir" ]] || die "core-config directory not found: $core_configs_dir"
[[ -f "$overlay_values" ]] || die "overlay values file not found: $overlay_values"

# Normalize the comma-separated selection, trim whitespace, and remove duplicates.
declare -a requested_services=()
IFS=',' read -r -a raw_services <<< "$bb_services_csv"
for raw_service in "${raw_services[@]}"; do
  service="$(printf '%s' "$raw_service" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -n "$service" ]] || die "--bb-services contains an empty service name"
  if [[ "$(printf '%s' "$service" | tr '[:lower:]' '[:upper:]')" == "ALL" ]]; then
    [[ ${#raw_services[@]} -eq 1 ]] || die "ALL cannot be combined with individual --bb-services entries"
    render_all_services=true
    continue
  fi
  already_requested=false
  for existing_service in "${requested_services[@]:-}"; do
    if [[ "$existing_service" == "$service" ]]; then
      already_requested=true
      break
    fi
  done
  if [[ "$already_requested" == false ]]; then
    requested_services+=("$service")
  fi
done

# Create a dated output tree for inputs, resolved values, and rendered releases.
# run_id="$(date +'%Y-%m-%d-%H%M%S')"
run_id="$(date +'%Y-%m-%d')"
run_dir="${output_root}/${k8s_env}-${k8s_impact_level}/${run_id}"
values_dir="${run_dir}/values"
services_dir="${run_dir}/services"
resolved_values_dir="${run_dir}/resolved-values"
mkdir -p "$cache_dir" "$values_dir" "$services_dir" "$resolved_values_dir"

# Clone the Big Bang umbrella repository, or optionally refresh an existing clone.
bigbang_repo_dir="${cache_dir}/bigbang"
if [[ ! -d "${bigbang_repo_dir}/.git" ]]; then
  log "Cloning Big Bang"
  git clone "$bigbang_repo_url" "$bigbang_repo_dir"
elif [[ "$refresh_repos" == true ]]; then
  log "Refreshing Big Bang"
  git -C "$bigbang_repo_dir" fetch --tags --prune
fi

# Check out the requested Big Bang tag/ref in detached mode for repeatable output.
git -C "$bigbang_repo_dir" checkout --detach "$bigbang_tag"

# Name the temporary and retained values files used for the umbrella render.
base_values="${values_dir}/base.yaml"
copied_overlay_values="${values_dir}/overlays.yaml"
extracted_base_documents="${values_dir}/base-documents.yaml"

# Find every top-level YAML core-config file in a stable alphabetical order.
declare -a core_config_files=()
while IFS= read -r config_file; do
  core_config_files+=("$config_file")
done < <(find "$core_configs_dir" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) | LC_ALL=C sort)
[[ ${#core_config_files[@]} -gt 0 ]] || die "no YAML files found in $core_configs_dir"

# Extract each ConfigMap's embedded values.yaml and merge them in file order.
# Copy the environment overlay separately so Helm applies it after the base.
log "Extracting base values from ${#core_config_files[@]} core-config files"
yq eval-all '
  select(.kind == "ConfigMap" and .data."values.yaml" != null) |
  .data."values.yaml" | from_yaml
' "${core_config_files[@]}" > "$extracted_base_documents"

[[ -s "$extracted_base_documents" ]] || die "no ConfigMap data.values.yaml documents found"
# shellcheck disable=SC2016 # $item belongs to yq and must not expand in Bash.
yq eval-all '. as $item ireduce ({}; . * $item)' "$extracted_base_documents" > "$base_values"
cp "$overlay_values" "$copied_overlay_values"
rm "$extracted_base_documents"

# The real TLS material is supplied through a Secret valuesFrom entry. Big Bang
# calls b64enc while rendering its umbrella chart, so empty maps cannot simply be
# omitted. Add obvious, non-secret placeholders to gateway maps in both inputs.
# Guard the update so an environment without gateway overrides does not get an
# empty gateways array that replaces the base gateway map during Helm's merge.
for values_file in "$base_values" "$copied_overlay_values"; do
  if [[ "$(yq -r '.istioGateway.values.gateways | type' "$values_file")" == "!!map" ]]; then
    yq -i '
      (.istioGateway.values.gateways[]?.gatewayCerts[]?.tls.cert) |=
        (. // "EXTERNAL_SECRET_OMITTED") |
      (.istioGateway.values.gateways[]?.gatewayCerts[]?.tls.key) |=
        (. // "EXTERNAL_SECRET_OMITTED")
    ' "$values_file"
  fi
done

# Render the umbrella chart, including APIs that may not exist in the active cluster.
umbrella_output="${run_dir}/bigbang-release.yaml"
log "Rendering the complete Big Bang umbrella release"
helm template bigbang "${bigbang_repo_dir}/chart" \
  --namespace bigbang \
  --kube-version "$kube_version" \
  --api-versions networking.istio.io/v1 \
  --api-versions kyverno.io/v1 \
  --skip-schema-validation \
  --values "$base_values" \
  --values "$copied_overlay_values" \
  > "$umbrella_output"

# Discover the child HelmRelease names that Big Bang enabled in the umbrella output.
declare -a enabled_releases=()
while IFS= read -r enabled_release; do
  enabled_releases+=("$enabled_release")
done < <(yq eval-all -N -r 'select(.kind == "HelmRelease") | .metadata.name' "$umbrella_output" | LC_ALL=C sort -u)

if [[ ${#enabled_releases[@]} -eq 0 ]]; then
  die "the Big Bang render produced no child HelmRelease objects"
fi

# Expand ALL into the complete list discovered from the rendered umbrella chart.
if [[ "$render_all_services" == true ]]; then
  requested_services=("${enabled_releases[@]}")
  log "Rendering all ${#requested_services[@]} enabled child releases"
fi

# Reject requested services that Big Bang did not render as enabled HelmReleases.
declare -a invalid_services=()
for service in "${requested_services[@]}"; do
  service_enabled=false
  for release in "${enabled_releases[@]}"; do
    if [[ "$release" == "$service" ]]; then
      service_enabled=true
      break
    fi
  done
  [[ "$service_enabled" == true ]] || invalid_services+=("$service")
done

if [[ ${#invalid_services[@]} -gt 0 ]]; then
  printf 'ERROR: requested service(s) are not enabled child HelmReleases: %s\n' "${invalid_services[*]}" >&2
  printf 'Enabled child HelmReleases:\n' >&2
  printf '  %s\n' "${enabled_releases[@]}" >&2
  exit 1
fi

# Choose whether child outputs represent a saved baseline or the current values.
summary_file="${run_dir}/render-summary.txt"
if [[ "$create_base_release" == true ]]; then
  render_mode="base"
  child_output_suffix="-base"
else
  render_mode="current"
  child_output_suffix=""
fi

# Describe whether the run selected explicit services or every enabled service.
if [[ "$render_all_services" == true ]]; then
  service_selection="all enabled child releases (${#requested_services[@]})"
else
  service_selection="requested child releases (${#requested_services[@]})"
fi

# Start a human-readable summary with the inputs and overall render settings.
printf 'Big Bang tag: %s\nKubernetes version: %s\nSimulated APIs: networking.istio.io/v1, kyverno.io/v1\nEnvironment: %s/%s\nRender mode: %s\nService selection: %s\nUmbrella: rendered\n\nChild releases:\n' \
  "$bigbang_tag" "$kube_version" "$k8s_env" "$k8s_impact_level" "$render_mode" "$service_selection" > "$summary_file"

# Resolve and render each selected child HelmRelease independently.
failures=0
declare -a rendered_service_outputs=()
for service in "${requested_services[@]}"; do
  log "Rendering child release: $service"

  # Extract this child's HelmRelease and read its chart, namespace, and source metadata.
  helmrelease_yaml="${resolved_values_dir}/${service}-helmrelease.yaml"
  yq eval-all "select(.kind == \"HelmRelease\" and .metadata.name == \"${service}\")" \
    "$umbrella_output" > "$helmrelease_yaml"

  target_namespace="$(yq -r '.spec.targetNamespace // .metadata.namespace' "$helmrelease_yaml")"
  child_release_name="$(yq -r '.spec.releaseName // .metadata.name' "$helmrelease_yaml")"
  chart_path="$(yq -r '.spec.chart.spec.chart' "$helmrelease_yaml")"
  source_kind="$(yq -r '.spec.chart.spec.sourceRef.kind' "$helmrelease_yaml")"
  source_name="$(yq -r '.spec.chart.spec.sourceRef.name' "$helmrelease_yaml")"

  # Child rendering currently supports charts stored in Flux GitRepository sources.
  if [[ "$source_kind" != "GitRepository" ]]; then
    log "WARNING: $service uses unsupported source kind $source_kind; skipping"
    record_failed_service "$service" "unsupported source kind: $source_kind"
    failures=$((failures + 1))
    continue
  fi

  # Extract the matching GitRepository object that tells us where the chart lives.
  git_source_yaml="${resolved_values_dir}/${service}-gitrepository.yaml"
  yq eval-all "select(.kind == \"GitRepository\" and .metadata.name == \"${source_name}\")" \
    "$umbrella_output" > "$git_source_yaml"

  if [[ ! -s "$git_source_yaml" ]]; then
    log "WARNING: GitRepository $source_name was not found for $service; skipping"
    record_failed_service "$service" "GitRepository not found"
    failures=$((failures + 1))
    continue
  fi

  child_repo_url="$(yq -r '.spec.url' "$git_source_yaml")"
  child_git_ref="$(yq -r '.spec.ref.tag // .spec.ref.branch // .spec.ref.commit // ""' "$git_source_yaml")"
  child_repo_dir="${cache_dir}/${source_name}"

  # Clone the child chart repository, or optionally fetch updates for a cached clone.
  if [[ ! -d "${child_repo_dir}/.git" ]]; then
    if ! git clone "$child_repo_url" "$child_repo_dir"; then
      log "WARNING: failed to clone $child_repo_url for $service"
      record_failed_service "$service" "clone failed"
      failures=$((failures + 1))
      continue
    fi
  elif [[ "$refresh_repos" == true ]]; then
    git -C "$child_repo_dir" fetch --tags --prune
  fi

  # Check out the exact tag, branch, or commit declared by the GitRepository.
  if [[ -n "$child_git_ref" ]] && ! git -C "$child_repo_dir" checkout --detach "$child_git_ref"; then
    log "WARNING: unable to checkout $child_git_ref for $service"
    record_failed_service "$service" "checkout failed: $child_git_ref"
    failures=$((failures + 1))
    continue
  fi

  # Find the generated values Secret referenced by the child HelmRelease.
  values_secret_name="$(
    yq -r '
      [.spec.valuesFrom[]? | select(.kind == "Secret") | .name] |
      map(select(test("-values$"))) | .[0] // ""
    ' "$helmrelease_yaml"
  )"
  if [[ -z "$values_secret_name" ]]; then
    values_secret_name="bigbang-${service}-values"
  fi

  # Extract that Secret from the umbrella output; it contains resolved child values.
  values_secret_yaml="${resolved_values_dir}/${service}-values-secret.yaml"
  yq eval-all "select(.kind == \"Secret\" and .metadata.name == \"${values_secret_name}\")" \
    "$umbrella_output" > "$values_secret_yaml"

  if [[ ! -s "$values_secret_yaml" ]]; then
    log "WARNING: generated values Secret $values_secret_name was not found for $service"
    record_failed_service "$service" "generated values Secret not found"
    failures=$((failures + 1))
    continue
  fi

  # Split common, default, and overlay values into Helm files in precedence order.
  common_values="${resolved_values_dir}/${service}-common.yaml"
  default_values="${resolved_values_dir}/${service}-defaults.yaml"
  child_overlay_values="${resolved_values_dir}/${service}-overlays.yaml"
  yq -r '.stringData.common' "$values_secret_yaml" > "$common_values"
  yq -r '.stringData.defaults' "$values_secret_yaml" > "$default_values"
  yq -r '.stringData.overlays' "$values_secret_yaml" > "$child_overlay_values"

  # Resolve the chart directory and skip the service if the declared path is absent.
  child_chart_dir="${child_repo_dir}/${chart_path#./}"
  child_output="${services_dir}/${service}-release${child_output_suffix}.yaml"
  if [[ ! -d "$child_chart_dir" ]]; then
    log "WARNING: chart path does not exist for $service: $child_chart_dir"
    record_failed_service "$service" "chart path not found: $chart_path"
    failures=$((failures + 1))
    continue
  fi

  # Render the child chart and record either its output path or its failure reason.
  if helm template "$child_release_name" "$child_chart_dir" \
    --namespace "$target_namespace" \
    --kube-version "$kube_version" \
    --api-versions networking.istio.io/v1 \
    --api-versions kyverno.io/v1 \
    --values "$common_values" \
    --values "$default_values" \
    --values "$child_overlay_values" \
    > "$child_output"; then
    record_rendered_service "$service" "$child_output"
    rendered_service_outputs+=("$child_output")
  else
    log "WARNING: Helm rendering failed for $service"
    rm -f "$child_output"
    record_failed_service "$service" "helm template failed"
    failures=$((failures + 1))
  fi
done

# Report output locations and return a failure when any requested child failed.
log "Render summary: $summary_file"
log "Umbrella output: $umbrella_output"

if [[ $failures -gt 0 ]]; then
  die "$failures requested child release(s) failed; see $summary_file"
fi

# Print every successfully rendered child manifest path for convenient follow-up.
log "All requested child releases rendered successfully"
for rendered_service_output in "${rendered_service_outputs[@]}"; do
  log "- $rendered_service_output"
done
