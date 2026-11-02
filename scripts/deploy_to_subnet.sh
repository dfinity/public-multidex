#!/usr/bin/env bash
# deploy_to_subnet.sh — deploy to subnet, and nowhere else.
#
# Thin by design: the target is in the FILENAME, so there is no flag to get
# wrong and no env var to forget. Guards (posture, identity) come from
# scripts/lib/targets.sh; the deploy itself is still scripts/deploy.sh, which
# owns the leg ordering and the anti-sybil origin re-assert.
#
#   bash scripts/deploy_to_subnet.sh              # full deploy
#   bash scripts/deploy_to_subnet.sh frontend     # frontend only
set -uo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib/targets.sh"
mdx_assert_posture_for_target "subnet"
mdx_assert_identity "subnet"
# H-02 (F8): the target must be the pinned one — mapping vs table, icp-cli
# resolution, controller set — before deploy.sh gets to build anything.
# deploy.sh re-runs the same pre-flight before remote_deploy (read-only,
# idempotent); the wrapper runs it first so a poisoned tree fails at the
# door, before gen-did and the candid regeneration even start.
mdx_assert_deploy_target "$(mdx_env_for subnet)" "$MDX_IDENTITY"
mdx_info "deploy → subnet (env $(mdx_env_for subnet), identity $MDX_IDENTITY, posture #$MDX_POSTURE, target verified)"
exec bash "$MDX_ROOT/scripts/deploy.sh" "subnet" "$@"
