#!/usr/bin/env bash
#
# Creates and configures the GCE machines used for a cluster.
#
set -e

cd "$(dirname "$0")"

#shellcheck source=/dev/null
source env.sh

usage() {
  exitcode=0
  if [[ -n "$1" ]]; then
    exitcode=1
    echo "Error: $*"
  fi
  cat <<EOF
usage: $0 [options]

Launch a cluster
   --release RELEASE_CHANNEL_OR_TAG    - Which release channel or tag to deploy (default: $RELEASE_CHANNEL_OR_TAG).

EOF
  exit $exitcode
}

while [[ -n $1 ]]; do
  if [[ ${1:0:2} = -- ]]; then
    if [[ $1 = --release ]]; then
      RELEASE_CHANNEL_OR_TAG="$2"
      shift 2
    else
      usage "Unknown long option: $1"
    fi
  else
    usage "Unknown option: $1"
  fi
done


ENTRYPOINT_INSTANCE=${INSTANCE_PREFIX}entrypoint
API_INSTANCE=${INSTANCE_PREFIX}api
WATCHTOWER_INSTANCE=${INSTANCE_PREFIX}watchtower

INSTANCES=(
  "$ENTRYPOINT_INSTANCE:$DEFAULT_ZONE"
  "$API_INSTANCE:$DEFAULT_ZONE"
  "$WATCHTOWER_INSTANCE:$DEFAULT_ZONE"
)

VALIDATOR_INSTANCES=()
for ZONE in "${VALIDATOR_ZONES[@]}"; do
  VALIDATOR_INSTANCES+=("${INSTANCE_PREFIX}validator-$ZONE:$ZONE")
  INSTANCES+=(         "${INSTANCE_PREFIX}validator-$ZONE:$ZONE")
done

WAREHOUSE_INSTANCES=()
for ZONE in "${WAREHOUSE_ZONES[@]}"; do
  WAREHOUSE_INSTANCES+=("${INSTANCE_PREFIX}warehouse-$ZONE:$ZONE")
  INSTANCES+=(          "${INSTANCE_PREFIX}warehouse-$ZONE:$ZONE")
done

LETSENCRYPT_TGZ=
if [[ -n $API_DNS_NAME ]]; then
  LETSENCRYPT_TGZ="letsencrypt-$API_DNS_NAME.tgz"
fi

if [[ $(basename "$0" .sh) = delete-cluster ]]; then
  if [[ -n $API_DNS_NAME ]]; then
    echo "Attempting to recover TLS certificate before deleting instances"
    (
      set -x
      gcloud --project "$PROJECT" compute scp --zone "$DEFAULT_ZONE" "$API_INSTANCE":/letsencrypt.tgz "$LETSENCRYPT_TGZ"
    ) || true
    if [[ -f "$LETSENCRYPT_TGZ" ]]; then
      echo "Warning: ensure you don't delete $LETSENCRYPT_TGZ"
    fi
  fi

  for INSTANCE_ZONE in "${INSTANCES[@]}"; do
    declare INSTANCE=${INSTANCE_ZONE%:*}
    declare ZONE=${INSTANCE_ZONE#*:}
    (
      set -x
      gcloud --project "$PROJECT" compute instances delete "$INSTANCE" --zone "$ZONE" --quiet
    ) &
    sleep 1
  done
  wait
  exit 0
fi


(
  set -x
  solana-gossip --version
  solana --version
)

if [[ ! -d "$CLUSTER"/ledger ]]; then
  echo "Error: $CLUSTER/ledger/ directory does not exist"
  exit 1
fi

TRUSTED_VALIDATOR_PUBKEYS=()
for ZONE in "${VALIDATOR_ZONES[@]}"; do
  declare KEYPAIR="$CLUSTER"/validator-identity-"$ZONE".json
  TRUSTED_VALIDATOR_PUBKEYS+=("$(solana-keygen pubkey $KEYPAIR)")
done

for INSTANCE_ZONE in "${INSTANCES[@]}"; do
  declare INSTANCE=${INSTANCE_ZONE%:*}
  declare ZONE=${INSTANCE_ZONE#*:}
  echo "Checking that $INSTANCE ($ZONE) does not exist"
  status=$(gcloud --project "$PROJECT" compute instances list --filter name="$INSTANCE" --format 'value(status)')
  if [[ -n $status ]]; then
    echo "Error: $INSTANCE already exists (status=$status)"
    exit 1
  fi
done


GENESIS_HASH="$(RUST_LOG=none solana-ledger-tool genesis-hash --ledger "$CLUSTER"/ledger)"
SHRED_VERSION="$(RUST_LOG=none solana-ledger-tool shred-version --ledger "$CLUSTER"/ledger)"

if [[ -z $SOLANA_METRICS_CONFIG ]]; then
  echo Note: SOLANA_METRICS_CONFIG is not configured
fi


for ZONE in "${WAREHOUSE_ZONES[@]}"; do
  declare REGION=${ZONE%-*}
  declare STORAGE_BUCKET="${STORAGE_BUCKET_PREFIX}-${REGION}"

  if [[ -n $RECREATE_STORAGE_BUCKET ]]; then
    # Re-create the dev bucket on each launch
    gsutil rm -r gs://"$STORAGE_BUCKET" || true
    gsutil mb -p "$PROJECT" -l "$REGION" -b on gs://"$STORAGE_BUCKET"
  else
    # Create the production bucket if it doesn't already exist but do not remove old
    # data, if any, to avoid accidental data loss.
    gsutil mb -p "$PROJECT" -l "$REGION" -b on gs://"$STORAGE_BUCKET" || true
  fi

  (
    set -x
    gsutil -m cp -r \
      "$CLUSTER"/ledger/genesis.tar.bz2 \
      "$CLUSTER"/*.json \
      "$CLUSTER"/genesis-summary.txt \
      gs://"$STORAGE_BUCKET"
  )

  (
    echo ZONE="$ZONE"
    echo STORAGE_BUCKET="$STORAGE_BUCKET"
  ) | tee "$CLUSTER"/service-env-warehouse-"$ZONE".sh
done


for ZONE in "${VALIDATOR_ZONES[@]}"; do
  (
    echo ZONE="$ZONE"
  ) | tee "$CLUSTER"/service-env-validator-"$ZONE".sh
done

(
  echo EXPECTED_GENESIS_HASH="$GENESIS_HASH"
  echo EXPECTED_SHRED_VERSION="$SHRED_VERSION"
  echo EXPECTED_BANK_HASH="8osXYbYF7drjZAJedHuwB8A56t7Pwa6bZbtCjiVhJBbT" # TODO: add ledger-tool command to fetch this correctly...
  echo TRUSTED_VALIDATOR_PUBKEYS="(${TRUSTED_VALIDATOR_PUBKEYS[*]})"
  echo WAIT_FOR_SUPERMAJORITY=0
  if [[ -n $SOLANA_METRICS_CONFIG ]]; then
    echo export SOLANA_METRICS_CONFIG="$SOLANA_METRICS_CONFIG"
  fi
  echo PATH=/home/sol/.local/share/solana/install/active_release/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin
  if [[ -n $DISCORD_WEBHOOK ]]; then
    echo DISCORD_WEBHOOK="$DISCORD_WEBHOOK"
  fi
  echo export RUST_BACKTRACE=1
) | tee "$CLUSTER"/service-env.sh

OS_IMAGE=ubuntu-minimal-2004-focal-v20200529

echo ==========================================================
echo "Creating $ENTRYPOINT_INSTANCE"
echo ==========================================================
(
  maybe_address=
  if [[ -n $ENTRYPOINT_ADDRESS_NAME ]]; then
    maybe_address="--address $ENTRYPOINT_ADDRESS_NAME"
  fi

  set -x
  gcloud --project "$PROJECT" compute instances create \
    "$ENTRYPOINT_INSTANCE" \
    --zone "$DEFAULT_ZONE" \
    --machine-type n1-standard-1 \
    --boot-disk-size=200GB \
    --tags solana-validator-minimal \
    --image "$OS_IMAGE" --image-project ubuntu-os-cloud \
    --min-cpu-platform "Intel Skylake" \
    ${maybe_address}
)

echo ==========================================================
echo "Creating $API_INSTANCE"
echo ==========================================================
(
  maybe_address=
  if [[ -n $API_ADDRESS_NAME ]]; then
    maybe_address="--address $(echo $API_ADDRESS_NAME | tr . -)"
  fi

  set -x
  gcloud --project "$PROJECT" compute instances create \
    "$API_INSTANCE" \
    --zone "$DEFAULT_ZONE" \
    --machine-type n1-standard-16 \
    --boot-disk-type=pd-ssd \
    --boot-disk-size=2TB \
    --tags solana-validator-minimal,solana-validator-rpc \
    --image "$OS_IMAGE" --image-project ubuntu-os-cloud \
    --min-cpu-platform "Intel Skylake" \
    ${maybe_address}
)

echo ==========================================================
echo "Creating $WATCHTOWER_INSTANCE"
echo ==========================================================
(
  set -x
  gcloud --project "$PROJECT" compute instances create \
    "$WATCHTOWER_INSTANCE" \
    --zone "$DEFAULT_ZONE" \
    --machine-type n1-standard-1 \
    --boot-disk-size=200GB \
    --tags solana-validator-minimal \
    --image "$OS_IMAGE" --image-project ubuntu-os-cloud \
    --min-cpu-platform "Intel Skylake" \

)

for INSTANCE_ZONE in "${VALIDATOR_INSTANCES[@]}"; do
  declare VALIDATOR_INSTANCE=${INSTANCE_ZONE%:*}
  declare ZONE=${INSTANCE_ZONE#*:}

  echo ==========================================================
  echo "Creating $VALIDATOR_INSTANCE in $ZONE"
  echo ==========================================================
  (
    set -x
    gcloud --project "$PROJECT" compute instances create \
      "$VALIDATOR_INSTANCE" \
      --zone "$ZONE" \
      --machine-type n1-standard-8 \
      --boot-disk-type=pd-ssd \
      --boot-disk-size=2TB \
      --tags solana-validator-minimal,solana-validator-rpc \
      --image "$OS_IMAGE" --image-project ubuntu-os-cloud \
      --min-cpu-platform "Intel Skylake" \

  )
done

for INSTANCE_ZONE in "${WAREHOUSE_INSTANCES[@]}"; do
  declare WAREHOUSE_INSTANCE=${INSTANCE_ZONE%:*}
  declare ZONE=${INSTANCE_ZONE#*:}

  echo ==========================================================
  echo "Creating $WAREHOUSE_INSTANCE in $ZONE"
  echo ==========================================================
  (
    set -x
    gcloud --project "$PROJECT" compute instances create \
      "$WAREHOUSE_INSTANCE" \
      --zone "$ZONE" \
      --machine-type n1-standard-8 \
      --boot-disk-type=pd-ssd \
      --boot-disk-size=2TB \
      --tags solana-validator-minimal,solana-validator-rpc \
      --image "$OS_IMAGE" --image-project ubuntu-os-cloud \
      --min-cpu-platform "Intel Skylake" \
      --scopes=storage-rw \

  )
done

ENTRYPOINT_HOST=$ENTRYPOINT_DNS_NAME
ENTRYPOINT_PORT=8001
RPC=$API_DNS_NAME
if [[ -z $ENTRYPOINT_HOST ]]; then
  ENTRYPOINT_HOST=$(gcloud --project "$PROJECT" compute instances list \
      --filter name="$ENTRYPOINT_INSTANCE" --format 'value(networkInterfaces[0].accessConfigs[0].natIP)')
fi
if [[ -z $RPC ]]; then
  RPC=$(gcloud --project "$PROJECT" compute instances list \
      --filter name="$API_INSTANCE" --format 'value(networkInterfaces[0].accessConfigs[0].natIP)')
fi
RPC_URL="http://$RPC/"
ENTRYPOINT="${ENTRYPOINT_HOST}:${ENTRYPOINT_PORT}"

cat >> "$CLUSTER"/service-env.sh <<EOF
RPC_URL=$RPC_URL
ENTRYPOINT_HOST=$ENTRYPOINT_HOST
ENTRYPOINT_PORT=$ENTRYPOINT_PORT
ENTRYPOINT=\$ENTRYPOINT_HOST:\$ENTRYPOINT_PORT
EOF


echo ==========================================================
echo Waiting for instances to boot
echo ==========================================================
# shellcheck disable=SC2068 # Don't want to double quote INSTANCES
for INSTANCE_ZONE in "${INSTANCES[@]}"; do
  declare INSTANCE=${INSTANCE_ZONE%:*}
  declare ZONE=${INSTANCE_ZONE#*:}
  while ! gcloud --project "$PROJECT" compute ssh --zone "$ZONE" "$INSTANCE" -- true; do
    echo "Waiting for \"$INSTANCE\" to boot"
    sleep 5s
  done
done

echo ==========================================================
echo "Transferring files to $ENTRYPOINT_INSTANCE"
echo ==========================================================
(
  set -x
  gcloud --project "$PROJECT" compute scp --zone "$DEFAULT_ZONE" --recurse \
    "$CLUSTER"/service-env.sh \
    bin/ \
    "$ENTRYPOINT_INSTANCE":

  gcloud --project "$PROJECT" compute ssh --zone "$DEFAULT_ZONE" "$ENTRYPOINT_INSTANCE" -- \
    bash bin/machine-setup.sh "$RELEASE_CHANNEL_OR_TAG" entrypoint ""
)

for INSTANCE_ZONE in "${VALIDATOR_INSTANCES[@]}"; do
  declare VALIDATOR_INSTANCE=${INSTANCE_ZONE%:*}
  declare ZONE=${INSTANCE_ZONE#*:}

  echo ==========================================================
  echo "Transferring files to $VALIDATOR_INSTANCE"
  echo ==========================================================
  (
    set -x
    gcloud --project "$PROJECT" compute scp --zone "$ZONE" --recurse \
      "$CLUSTER"/validator-identity-"$ZONE".json \
      "$CLUSTER"/validator-stake-account-"$ZONE".json \
      "$CLUSTER"/validator-vote-account-"$ZONE".json \
      "$CLUSTER"/service-env.sh \
      "$CLUSTER"/service-env-validator-"$ZONE".sh \
      "$CLUSTER"/ledger \
      bin/ \
      "$VALIDATOR_INSTANCE":

    gcloud --project "$PROJECT" compute ssh --zone "$ZONE" "$VALIDATOR_INSTANCE" -- \
      bash bin/machine-setup.sh "$RELEASE_CHANNEL_OR_TAG" validator ""
  )
done

for INSTANCE_ZONE in "${WAREHOUSE_INSTANCES[@]}"; do
  declare WAREHOUSE_INSTANCE=${INSTANCE_ZONE%:*}
  declare ZONE=${INSTANCE_ZONE#*:}

  echo ==========================================================
  echo "Transferring files to $WAREHOUSE_INSTANCE"
  echo ==========================================================
  (
    set -x
    gcloud --project "$PROJECT" compute scp --zone "$ZONE" --recurse \
      "$CLUSTER"/warehouse-identity-"$ZONE".json \
      "$CLUSTER"/ledger \
      "$CLUSTER"/service-env.sh \
      "$CLUSTER"/service-env-warehouse-"$ZONE".sh \
      bin/ \
      "$WAREHOUSE_INSTANCE":

    gcloud --project "$PROJECT" compute ssh --zone "$ZONE" "$WAREHOUSE_INSTANCE" -- \
      bash bin/machine-setup.sh "$RELEASE_CHANNEL_OR_TAG" warehouse ""
  )
done

echo ==========================================================
echo "Transferring files to $WATCHTOWER_INSTANCE"
echo ==========================================================
(
  set -x
  gcloud --project "$PROJECT" compute scp --zone "$DEFAULT_ZONE" --recurse \
    "$CLUSTER"/service-env.sh \
    bin/ \
    "$WATCHTOWER_INSTANCE":
  gcloud --project "$PROJECT" compute ssh --zone "$DEFAULT_ZONE" "$WATCHTOWER_INSTANCE" -- \
    bash bin/machine-setup.sh "$RELEASE_CHANNEL_OR_TAG" watchtower ""
)

echo ==========================================================
echo "Transferring files to $API_INSTANCE"
echo ==========================================================
(
  set -x
  gcloud --project "$PROJECT" compute scp --zone "$DEFAULT_ZONE" --recurse \
    "$CLUSTER"/api-identity.json \
    "$CLUSTER"/ledger \
    "$CLUSTER"/service-env.sh \
    bin/ \
    "$API_INSTANCE":

)
if [[ -n $FAUCET_RPC ]]; then
  (
    set -x
    gcloud --project "$PROJECT" compute scp --zone "$DEFAULT_ZONE" "$CLUSTER"/faucet.json "$API_INSTANCE":
  )
fi

if [[ -n $LETSENCRYPT_TGZ ]] && [[ -f $LETSENCRYPT_TGZ ]]; then
  (
    set -x
    gcloud --project "$PROJECT" compute scp --zone "$DEFAULT_ZONE" "$LETSENCRYPT_TGZ" "$API_INSTANCE":~/letsencrypt.tgz
    gcloud --project "$PROJECT" compute ssh --zone "$DEFAULT_ZONE" "$API_INSTANCE" -- sudo mv letsencrypt.tgz /
  )
fi

(
  set -x
  gcloud --project "$PROJECT" compute ssh --zone "$DEFAULT_ZONE" "$API_INSTANCE" -- \
    bash bin/machine-setup.sh "$RELEASE_CHANNEL_OR_TAG" api "$API_DNS_NAME"
)


echo ==========================================================
(
  set -x
  solana-gossip spy --entrypoint "$ENTRYPOINT" --timeout 10
)
echo ==========================================================
(
  set -x
  solana --url "$RPC_URL" cluster-version
  solana --url "$RPC_URL" get-genesis-hash
  solana --url "$RPC_URL" get-epoch-info
  solana --url "$RPC_URL" show-validators
)

echo ==========================================================
(
  ./get-all-accounts-owned-in-genesis.sh "$RPC_URL"
) | tee accounts_owned_by.txt

(
  set -x
  gsutil -m cp accounts_owned_by* gs://"$STORAGE_BUCKET"
)

echo ==========================================================
(
  set -x
  gcloud --project "$PROJECT" compute instances list
)
echo ==========================================================
echo Success
exit 0
