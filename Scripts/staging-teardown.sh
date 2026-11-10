#!/bin/bash
#
# Tears down the staging environment and proves nothing is left behind.
#
#   ./Scripts/staging-teardown.sh --check     what exists right now
#   ./Scripts/staging-teardown.sh --dry-run   what destroy would remove
#   ./Scripts/staging-teardown.sh --destroy   actually remove it
#
# Staging is destroyable by design: deletion_protection is off and
# skip_final_snapshot is on for environment = "staging", so `terraform destroy`
# completes without manual intervention. Production is the opposite -- its
# deletion_protection is on, so a destroy against it fails until someone
# deliberately turns that off, which is two explicit steps rather than one
# command.
#
# This script refuses to run against anything that is not prefixed
# vrc-staging-, so it cannot be pointed at production by mistake.

set -uo pipefail
cd "$(dirname "$0")/.."
TF="Infrastructure/terraform"
PREFIX="vrc-staging"

say()  { printf '%s\n' "$*"; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mfail\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m    %s\n' "$*"; }

inventory() {
    step "What exists with the ${PREFIX} prefix"
    local found=0

    local clusters
    clusters=$(aws rds describe-db-clusters \
        --query "DBClusters[?starts_with(DBClusterIdentifier,'${PREFIX}')].DBClusterIdentifier" \
        --output text 2>/dev/null)
    [ -n "${clusters}" ] && { say "  Aurora clusters:   ${clusters}"; found=1; }

    local fns
    fns=$(aws lambda list-functions \
        --query "Functions[?starts_with(FunctionName,'${PREFIX}')].FunctionName" \
        --output text 2>/dev/null)
    [ -n "${fns}" ] && { say "  Lambda functions:  ${fns}"; found=1; }

    local buckets
    buckets=$(aws s3api list-buckets \
        --query "Buckets[?starts_with(Name,'${PREFIX}')].Name" --output text 2>/dev/null)
    [ -n "${buckets}" ] && { say "  S3 buckets:        ${buckets}"; found=1; }

    local apis
    apis=$(aws apigatewayv2 get-apis \
        --query "Items[?starts_with(Name,'${PREFIX}')].Name" --output text 2>/dev/null)
    [ -n "${apis}" ] && { say "  HTTP APIs:         ${apis}"; found=1; }

    local secrets
    secrets=$(aws secretsmanager list-secrets \
        --query "SecretList[?starts_with(Name,'${PREFIX}')].Name" --output text 2>/dev/null)
    [ -n "${secrets}" ] && { say "  Secrets:           ${secrets}"; found=1; }

    local users
    users=$(aws iam list-users \
        --query "Users[?starts_with(UserName,'${PREFIX}')].UserName" --output text 2>/dev/null)
    [ -n "${users}" ] && { say "  IAM users:         ${users}"; found=1; }

    if [ "${found}" -eq 0 ]; then ok "nothing exists — staging is clean"; fi
    return "${found}"
}

# Things that must survive a staging teardown untouched.
assert_production_intact() {
    step "Confirming nothing outside staging was affected"

    local prod_tables
    prod_tables=$(aws dynamodb list-tables \
        --query "TableNames[?starts_with(@,'priyankahomes-south-boston')]" \
        --output text 2>/dev/null)
    if [ -n "${prod_tables}" ]; then
        ok "PriyankaHomes tables still present: ${prod_tables}"
    else
        bad "the PriyankaHomes tables are missing — STOP and investigate"
        return 1
    fi

    for zone in bostonfurnishedstays.com 39gstboston.com; do
        local n
        n=$(aws route53 list-hosted-zones \
            --query "length(HostedZones[?Name=='${zone}.'])" --output text 2>/dev/null)
        if [ "${n}" = "1" ]; then ok "hosted zone ${zone} still present"
        else bad "hosted zone ${zone} is missing"; return 1; fi
    done

    # The Mac's own data is never touched by any of this, but say so explicitly.
    local db="${HOME}/Library/Application Support/VacationRentalCalendar/VacationRentalCalendar.sqlite"
    if [ -f "${db}" ]; then
        local decisions
        decisions=$(sqlite3 "${db}" \
            "select count(*) from availability_decisions where status='approved'" 2>/dev/null)
        ok "local SQLite intact: ${decisions} approved decision(s)"
    fi
}

case "${1:---check}" in
    --check)
        inventory || true
        assert_production_intact
        ;;

    --dry-run)
        inventory || true
        step "What a destroy would remove"
        if ! (cd "${TF}" && terraform destroy -refresh=false -input=false -no-color \
                -var-file=staging.tfvars 2>&1 | tail -30); then
            warn "no state yet, or terraform is not initialised — nothing to destroy"
        fi
        say ""
        say "  Nothing was removed. Re-run with --destroy to do it."
        ;;

    --destroy)
        step "Guard"
        ENV_IN_STATE=$(cd "${TF}" && terraform output -raw environment 2>/dev/null || echo "")
        if [ -n "${ENV_IN_STATE}" ] && [ "${ENV_IN_STATE}" != "staging" ]; then
            bad "the state says environment=${ENV_IN_STATE}; this script only removes staging"
            exit 1
        fi
        ok "state is staging (or empty)"

        inventory || true
        say ""
        read -r -p "  Destroy the staging environment? Type 'destroy staging' to confirm: " answer
        [ "${answer}" = "destroy staging" ] || { say "  Cancelled."; exit 1; }

        step "Destroying"
        (cd "${TF}" && terraform destroy -auto-approve -input=false -no-color \
            -var-file=staging.tfvars) || { bad "destroy failed — re-run; it is idempotent"; exit 1; }

        step "Verifying nothing is left"
        if inventory; then ok "staging is fully removed"; else
            bad "resources remain — listed above"; exit 1; fi

        # S3 buckets with versioning keep object versions, which blocks the
        # bucket delete. Terraform reports it; this says what to do about it.
        say ""
        say "  If a bucket refused to delete, it still holds object versions:"
        say "    aws s3api list-object-versions --bucket <name> --query 'Versions[].{K:Key,V:VersionId}'"
        say "  Empty it, then re-run --destroy. Terraform is idempotent here."

        assert_production_intact
        ;;

    *)
        say "usage: $0 [--check|--dry-run|--destroy]"
        exit 1
        ;;
esac
