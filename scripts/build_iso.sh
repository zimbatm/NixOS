#! /usr/bin/env bash

base_dir="$(dirname "${BASH_SOURCE}")/../"

nix-build "${base_dir}/eval_all_hosts.nix" \
  --attr rescue-iso-img \
  --arg prod_build true

if [ "${?}" -eq "0" ]; then
  echo -e "\nThe ISO can be found in result/iso.\n"
else
  exit 1
fi

