#!/usr/bin/env bash
# Tests for the apply-bucket-policies.sh script embedded in
# fluxer/bucket-policy-job.yaml, run against a fake `aws` binary (no NooBaa needed).
#
# The script is extracted from the ConfigMap exactly as Kubernetes would mount it,
# so the test exercises the shipped code, not a copy.
#
# What is covered:
#   - happy path: one put-bucket-policy per non-CDN bucket, signed by that bucket's
#     OWN credentials, with a policy whose principals are exactly that bucket's
#     account ARN and the CDN account ARN; then put/head/delete probes on all four
#     buckets with Fluxer's (CDN) credentials
#   - input validation: missing environment, an empty CA bundle and a principal
#     that is not an account ARN exit 2 with an actionable message
#   - failure propagation: an AccessDenied from S3 fails the script
#
# Usage: fluxer/tests/bucket-policy-script.test.sh   (needs bash, yq, jq)
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
manifest="$repo_root/fluxer/bucket-policy-job.yaml"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

script="$work/apply-bucket-policies.sh"
yq 'select(.kind == "ConfigMap") | .data["apply-bucket-policies.sh"]' "$manifest" >"$script"

# Fake aws: records "<access-key-id> <subcommand> <bucket>" per call and validates
# the policy document of put-bucket-policy. FAKE_DENY_BUCKET makes every call on
# that bucket fail like an S3 AccessDenied.
mkdir -p "$work/bin"
cat >"$work/bin/aws" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
sub="" bucket="" policy=""
while [ $# -gt 0 ]; do
  case "$1" in
    put-bucket-policy|put-object|head-object|delete-object) sub=$1 ;;
    --bucket) bucket=$2; shift ;;
    --policy) policy=$2; shift ;;
  esac
  shift
done
echo "${AWS_ACCESS_KEY_ID} ${sub} ${bucket}" >>"$FAKE_AWS_LOG"
if [ -n "${FAKE_DENY_BUCKET:-}" ] && [ "$bucket" = "$FAKE_DENY_BUCKET" ]; then
  echo "An error occurred (AccessDenied) when calling the ${sub} operation: Access Denied" >&2
  exit 254
fi
if [ "$sub" = "put-bucket-policy" ]; then
  # Owner ARNs encode the bucket in the fake account ID (see base_env below).
  case "$bucket" in
    fluxer-uploads) owner="arn:aws:iam::0000000000000000000000a1:root" ;;
    fluxer-reports) owner="arn:aws:iam::0000000000000000000000a2:root" ;;
    fluxer-harvests) owner="arn:aws:iam::0000000000000000000000a3:root" ;;
    *) echo "fake aws: policy for unexpected bucket $bucket" >&2; exit 1 ;;
  esac
  printf '%s' "$policy" | jq -e --arg b "$bucket" --arg owner "$owner" \
    --arg grantee "arn:aws:iam::0000000000000000000000c0:root" '
      .Version == "2012-10-17"
      and ([.Statement[] | select(.Effect == "Allow" and .Action == ["s3:*"]
             and .Resource == ["arn:aws:s3:::" + $b, "arn:aws:s3:::" + $b + "/*"])
            | .Principal.AWS[]] | sort == ([$owner, $grantee] | sort))
    ' >/dev/null || { echo "fake aws: invalid policy for $bucket: $policy" >&2; exit 1; }
fi
FAKE
chmod +x "$work/bin/aws"

touch "$work/ca.crt"
printf 'dummy-ca\n' >"$work/ca.crt"

base_env=(
  "PATH=$work/bin:$PATH"
  "HOME=$work"
  "FAKE_AWS_LOG=$work/aws.log"
  "S3_ENDPOINT=https://s3.example.invalid:443"
  "CA_BUNDLE=$work/ca.crt"
  "CDN_BUCKET=fluxer" "CDN_ACCESS_KEY_ID=cdn-key" "CDN_SECRET_ACCESS_KEY=cdn-secret"
  "UPLOADS_BUCKET=fluxer-uploads" "UPLOADS_ACCESS_KEY_ID=uploads-key" "UPLOADS_SECRET_ACCESS_KEY=uploads-secret"
  "REPORTS_BUCKET=fluxer-reports" "REPORTS_ACCESS_KEY_ID=reports-key" "REPORTS_SECRET_ACCESS_KEY=reports-secret"
  "HARVESTS_BUCKET=fluxer-harvests" "HARVESTS_ACCESS_KEY_ID=harvests-key" "HARVESTS_SECRET_ACCESS_KEY=harvests-secret"
  "CDN_ACCOUNT_ARN=arn:aws:iam::0000000000000000000000c0:root"
  "UPLOADS_ACCOUNT_ARN=arn:aws:iam::0000000000000000000000a1:root"
  "REPORTS_ACCOUNT_ARN=arn:aws:iam::0000000000000000000000a2:root"
  "HARVESTS_ACCOUNT_ARN=arn:aws:iam::0000000000000000000000a3:root"
)

failures=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; failures=$((failures + 1)); }

# run_script <extra env...>: runs the script with a clean environment, capturing
# combined output in $work/out and the exit code in $rc.
run_script() {
  : >"$work/aws.log"
  set +e
  env -i "${base_env[@]}" "$@" bash "$script" >"$work/out" 2>&1
  rc=$?
  set -e
}

# --- happy path --------------------------------------------------------------
run_script
if [ "$rc" -eq 0 ] && grep -q 'all Fluxer buckets are reachable' "$work/out"; then
  pass "happy path exits 0"
else
  fail "happy path: rc=$rc, output: $(cat "$work/out")"
fi

expected_policy_calls=$'uploads-key put-bucket-policy fluxer-uploads\nreports-key put-bucket-policy fluxer-reports\nharvests-key put-bucket-policy fluxer-harvests'
if [ "$(grep put-bucket-policy "$work/aws.log")" = "$expected_policy_calls" ]; then
  pass "each policy is applied once, with the owning bucket's credentials"
else
  fail "unexpected put-bucket-policy calls: $(grep put-bucket-policy "$work/aws.log" || true)"
fi

probe_calls=$(grep -v put-bucket-policy "$work/aws.log")
if [ "$(wc -l <<<"$probe_calls")" -eq 12 ] && ! grep -qv '^cdn-key ' <<<"$probe_calls"; then
  pass "4 buckets x put/head/delete probes, all with Fluxer's CDN credentials"
else
  fail "unexpected probe calls: $probe_calls"
fi

# --- input validation --------------------------------------------------------
run_script "REPORTS_SECRET_ACCESS_KEY="
if [ "$rc" -eq 2 ] && grep -q 'missing required environment: REPORTS_SECRET_ACCESS_KEY' "$work/out" \
  && [ ! -s "$work/aws.log" ]; then
  pass "missing credentials exit 2, name the variable and call no S3 API"
else
  fail "missing env: rc=$rc, output: $(cat "$work/out")"
fi

: >"$work/empty.crt"
run_script "CA_BUNDLE=$work/empty.crt"
if [ "$rc" -eq 2 ] && grep -q 'fluxer-service-ca' "$work/out" && [ ! -s "$work/aws.log" ]; then
  pass "empty CA bundle exits 2 and points at the fluxer-service-ca ConfigMap"
else
  fail "empty CA: rc=$rc, output: $(cat "$work/out")"
fi

# The account-name form from the ODF docs example, which NooBaa 4.22 rejects.
run_script "REPORTS_ACCOUNT_ARN=obc-account.fluxer-reports.6acbb4a5@noobaa.io"
if [ "$rc" -eq 2 ] && grep -q 'REPORTS_ACCOUNT_ARN=.* is not a NooBaa account ARN' "$work/out" \
  && grep -q 'additionalState.arn' "$work/out" && [ ! -s "$work/aws.log" ]; then
  pass "a non-ARN principal exits 2 with the refresh command and calls no S3 API"
else
  fail "bad ARN: rc=$rc, output: $(cat "$work/out")"
fi

# --- failure propagation -----------------------------------------------------
run_script "FAKE_DENY_BUCKET=fluxer-harvests"
if [ "$rc" -ne 0 ] && grep -q 'AccessDenied' "$work/out" && ! grep -q 'all Fluxer buckets are reachable' "$work/out"; then
  pass "an S3 AccessDenied fails the script"
else
  fail "deny: rc=$rc, output: $(cat "$work/out")"
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed" >&2
  exit 1
fi
echo "all tests passed"
