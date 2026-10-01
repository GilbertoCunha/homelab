#!/usr/bin/env bash
# Renders what ArgoCD would apply from a checkout of this repo, one file per
# source, so that two checkouts can be compared with `diff`.
#
#   .github/render.sh <checkout> <output directory>
#
# `task cluster:render` only proves the overlays build. An Application that
# installs a Helm chart is rendered by ArgoCD, in the cluster, so a chart
# version bump shows there as one changed line. This templates each chart with
# the values its Application gives it, which is what shows a changed default or
# a renamed field before it is merged.
#
# Used by `task cluster:render:diff`, and through it by the pull request check
# in .github/workflows/check.yaml.
set -euo pipefail

tree=$1
out=$2
mkdir -p "$out"

# Charts template differently per Kubernetes version. This is the one the
# cluster runs.
kube_version=$(sed -n 's/^kubernetes_version *= *"\(.*\)"/\1/p' "$tree/opentofu/project/terraform.tfvars")

for overlay in crds system applications; do
  kustomize build --enable-helm "$tree/gitops/$overlay/overlays/production" > "$out/$overlay.yaml"
done

# Every Application that names a chart. An Application reading a chart out of a
# git repository is skipped: its change still shows in the overlay's own file.
yq ea -o=json -I=0 'select(.kind == "Application" and .spec.source.chart != null)' \
  "$out/system.yaml" "$out/applications.yaml" |
  while read -r app; do
    name=$(jq -r '.metadata.name' <<< "$app")
    chart=$(jq -r '.spec.source.chart' <<< "$app")
    repo=$(jq -r '.spec.source.repoURL' <<< "$app")

    values=$(mktemp)
    jq '.spec.source.helm.valuesObject // {}' <<< "$app" > "$values"

    args=(
      "$(jq -r '.spec.source.helm.releaseName // .metadata.name' <<< "$app")"
      --namespace "$(jq -r '.spec.destination.namespace' <<< "$app")"
      --version "$(jq -r '.spec.source.targetRevision' <<< "$app")"
      --kube-version "$kube_version"
      --values "$values"
    )
    if [ "$(jq -r '.spec.source.helm.skipCrds // false' <<< "$app")" != true ]; then
      args+=(--include-crds)
    fi
    while read -r parameter; do
      args+=(--set "$parameter")
    done < <(jq -r '.spec.source.helm.parameters // [] | .[] | "\(.name)=\(.value)"' <<< "$app")

    # A repository without a scheme is an OCI registry, which is how ArgoCD
    # reads it too.
    case "$repo" in
      http://* | https://*) helm template "${args[@]}" "$chart" --repo "$repo" > "$out/chart-$name.yaml" ;;
      *) helm template "${args[@]}" "oci://$repo/$chart" > "$out/chart-$name.yaml" ;;
    esac
    rm -f "$values"
  done

# The project chart, once per catalog entry. ArgoCD renders these from git.
for project in "$tree"/gitops/applications/catalog/*.yaml; do
  name=$(basename "$project" .yaml)
  helm template "$name" "$tree/gitops/charts/project" -f "$project" > "$out/project-$name.yaml"
done
