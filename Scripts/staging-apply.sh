#!/bin/bash
#
# Applies the exact plan file that preflight validated.
#
#   ./Scripts/staging-apply.sh
#
# Safeguard 2: this never generates a plan. It applies
# Infrastructure/terraform/staging.tfplan and refuses unless that file still
# hashes to what Scripts/staging-preflight.sh recorded in its receipt. A plan
# regenerated at apply time is a different plan -- providers move and AWS
# retires engine versions -- so "apply what was reviewed" has to be mechanical
# rather than a habit.
#
# It also re-checks the account and region, because a credential change between
# preflight and apply would otherwise go unnoticed.

set -uo pipefail
cd "$(dirname "$0")/.."
TF="Infrastructure/terraform"
PLAN="${TF}/staging.tfplan"
RECEIPT="${TF}/staging.tfplan.receipt"
EXPECTED_ACCOUNT_SUFFIX="1110"
EXPECTED_REGION="us-east-1"

say()  { printf '%b\n' "$*"; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mNO\033[0m   %s\n' "$*"; }
stop() { say ""; say "  \033[31mREFUSING TO APPLY\033[0m — $*"; exit 1; }

step "1. The receipt"
[ -f "${RECEIPT}" ] || stop "no receipt. Run ./Scripts/staging-preflight.sh first."
# shellcheck disable=SC1090
VERDICT=$(grep '^verdict=' "${RECEIPT}" | cut -d= -f2)
RECORDED=$(grep '^plan_sha256=' "${RECEIPT}" | cut -d= -f2)
RECORDED_AT=$(grep '^at=' "${RECEIPT}" | cut -d= -f2)
RESOURCES=$(grep '^resources=' "${RECEIPT}" | cut -d= -f2)
[ "${VERDICT}" = "GO" ] || stop "the receipt says verdict=${VERDICT:-unknown}, not GO."
ok "verdict GO, recorded ${RECORDED_AT}"

step "2. The plan file is the one that was validated"
[ -f "${PLAN}" ] || stop "${PLAN} is missing. Re-run preflight."
ACTUAL=$(shasum -a 256 "${PLAN}" | awk '{print $1}')
if [ "${ACTUAL}" != "${RECORDED}" ]; then
    bad "recorded: ${RECORDED}"
    bad "actual:   ${ACTUAL}"
    stop "the plan file changed since it was validated. Re-run preflight."
fi
ok "sha256 matches: ${ACTUAL}"

step "3. Still the right account and region"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
[ -n "${ACCOUNT}" ] || stop "cannot determine the AWS account."
[ "${ACCOUNT: -4}" = "${EXPECTED_ACCOUNT_SUFFIX}" ] \
    || stop "account ends …${ACCOUNT: -4}, expected …${EXPECTED_ACCOUNT_SUFFIX}."
ok "account ends …${EXPECTED_ACCOUNT_SUFFIX}"
REGION="$(aws configure get region 2>/dev/null)"
[ "${REGION}" = "${EXPECTED_REGION}" ] || stop "region is ${REGION:-unknown}, expected ${EXPECTED_REGION}."
ok "region ${EXPECTED_REGION}"

step "4. Confirmation"
say "  This will create ${RESOURCES} resources in account …${EXPECTED_ACCOUNT_SUFFIX},"
say "  region ${EXPECTED_REGION}, at roughly \$2.12/month."
say ""
say "  It will NOT enable outbound publishing, enable any schedule, create any"
say "  DNS record, or grant access to the PriyankaHomes tables."
say ""
read -r -p "  Type 'apply staging' to proceed: " answer
[ "${answer}" = "apply staging" ] || { say "  Cancelled. Nothing applied."; exit 1; }

step "5. Applying the saved plan"
# No -var-file: a saved plan already carries its variables, and passing them
# again would be refused by Terraform.
(cd "${TF}" && terraform apply -input=false -no-color "staging.tfplan") || {
    bad "apply failed"
    say "  The plan file is now stale. Re-run preflight before trying again."
    rm -f "${RECEIPT}"
    exit 1
}

# A plan can only be applied once; the receipt must not invite a second go.
rm -f "${RECEIPT}" "${PLAN}"
step "Applied"
say "  The plan file and receipt were removed: a saved plan is single-use."
say ""
say "  Next, per docs/STAGING-DEPLOYMENT.md:"
say "    A3  vrc-migrate --apply 010 then 011"
say "    A4  set the vrc_runtime password into Secrets Manager, out of band"
say "    A5  ./Scripts/build-lambda.sh --deploy"
say "    B1-B9  smoke tests, schedules still disabled"
say ""
say "  Schedules remain DISABLED. Outbound publication remains off."
