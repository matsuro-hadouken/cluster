#!/usr/bin/env bash
set -ex

~/bin/check-hostname.sh

#shellcheck source=/dev/null
. ~/service-env.sh

identity_keypair=~/api-identity.json
identity_pubkey=$(solana-keygen pubkey $identity_keypair)

trusted_validators=()
for tv in "${TRUSTED_VALIDATOR_PUBKEYS[@]}"; do
  [[ $tv = "$identity_pubkey" ]] || trusted_validators+=(--trusted-validator "$tv")
done

if [[ -f ~/faucet.json ]]; then
  maybe_rpc_faucet_address="--rpc-faucet-address 127.0.0.1:9900"
fi

if [[ -n $GOOGLE_APPLICATION_CREDENTIALS ]]; then
  maybe_rpc_big_table_storage="--enable-rpc-bigtable-ledger-storage"
fi

if [[ -n "$EXPECTED_BANK_HASH" ]]; then
  maybe_expected_bank_hash="--expected-bank-hash $EXPECTED_BANK_HASH"
  if [[ -n "$WAIT_FOR_SUPERMAJORITY" ]]; then
    maybe_wait_for_supermajority="--wait-for-supermajority $WAIT_FOR_SUPERMAJORITY"
  fi
elif [[ -n "$WAIT_FOR_SUPERMAJORITY" ]]; then
  echo "WAIT_FOR_SUPERMAJORITY requires EXPECTED_BANK_HASH be specified as well!" 1>&2
  exit 1
fi

exec solana-validator \
  --gossip-port 8001 \
  --dynamic-port-range 8002-8012 \
  --entrypoint "${ENTRYPOINT}" \
  --ledger ~/ledger \
  --identity "$identity_keypair" \
  --limit-ledger-size 600000000 \
  --log ~/solana-validator.log \
  --no-genesis-fetch --no-snapshot-fetch \
  --no-voting \
  --rpc-port 8899 \
  --enable-rpc-transaction-history \
  ${maybe_rpc_faucet_address} \
  ${maybe_rpc_big_table_storage} \
  --expected-genesis-hash "$EXPECTED_GENESIS_HASH" \
  --expected-shred-version "$EXPECTED_SHRED_VERSION" \
  ${maybe_expected_bank_hash} \
  ${maybe_wait_for_supermajority} \
  "${trusted_validators[@]}" \
  --no-untrusted-rpc \
