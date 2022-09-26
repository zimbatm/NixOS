#!/usr/bin/env bash
set -e

# To install, run:
# curl -L https://github.com/msf-ocb/nixos/raw/master/install.sh | sudo bash -s -- -d <disk device> -h <host name>

function wait_for_devices() {
  arr=("${@}")
  devs="${arr[@]}"
  all_found=false
  for dev in ${devs}; do
    udevadm settle --exit-if-exists=${dev}
  done
  for countdown in $( seq 60 -1 0 ); do
    missing=false
    for dev in ${devs}; do
      if [ ! -b ${dev} ]; then
        missing=true
        echo "waiting for ${dev}... (${countdown})"
      fi
    done
    if [ "${missing}" = true ]; then
      partprobe ${DEVICE}
      sleep 1
      for dev in ${devs}; do
        udevadm settle --exit-if-exists=${dev}
      done
    else
      all_found=true
      break;
    fi
  done
  if [ "${all_found}" != true ]; then
    echo "Time-out waiting for devices."
    exit 1
  fi
}

function exit_usage() {
  cat <<EOF
Usage:
  install.sh -d <device> -h <hostname> [-r <root size (GB)>] [-l] [-D]
    -l triggers legacy installation mode instead of UEFI
    -D causes the creation of an encrypted data partition to be skipped
EOF
  exit 1
}

function exit_missing_arg() {
  echo "Error: -${1} requires an argument"
  exit_usage
}

while getopts ':d:h:r:lD' flag; do
  case "${flag}" in
    d  )
      if [[ "${OPTARG}" =~ ^-. ]]; then
        OPTIND=$OPTIND-1
      else
        DEVICE="${OPTARG}"
      fi
      if [[ -z "${DEVICE}" ]]; then
        exit_missing_arg "${flag}"
      fi
      ;;
    h  )
      if [[ "${OPTARG}" =~ ^-. ]]; then
        OPTIND=$OPTIND-1
      else
        TARGET_HOSTNAME="${OPTARG}"
      fi
      if [[ -z "${TARGET_HOSTNAME}" ]]; then
        exit_missing_arg "${flag}"
      fi
      ;;
    r  )
      if [[ "${OPTARG}" =~ ^-. ]]; then
        OPTIND=$OPTIND-1
      else
        ROOT_SIZE="${OPTARG}"
      fi
      if [[ -z "${ROOT_SIZE}" ]]; then
        exit_missing_arg "${flag}"
      fi
      ;;
    l  )
      USE_UEFI=false
      ;;
    D  )
      CREATE_DATA_PART=false
      ;;
    :  )
      exit_missing_arg "${OPTARG}"
      ;;
    \? )
      echo "Invalid option: -${OPTARG}"
      exit_usage
      ;;
    *  )
      exit_usage
      ;;
  esac
done

ROOT_SIZE="${ROOT_SIZE:-25}"
USE_UEFI="${USE_UEFI:=true}"
CREATE_DATA_PART="${CREATE_DATA_PART:=true}"

swapfile="/mnt/swapfile"

github_org_name="MSF-OCB"
main_repo_name="NixOS"
config_repo_name="NixOS-OCB-config"
main_repo="git@github.com:${github_org_name}/${main_repo_name}.git"
config_repo="git@github.com:${github_org_name}/${config_repo_name}.git"

nixos_dir="/mnt/etc/nixos/"
config_dir="${nixos_dir}/org-config/"

github_nixos_robot_name="OCB NixOS Robot"
github_nixos_robot_email="69807852+nixos-ocb@users.noreply.github.com"

if [ $EUID -ne 0 ]; then
  echo "Error this script should be run using sudo or as the root user"
  exit 1
fi

if [ -z "${DEVICE}" ] || [ -z "${TARGET_HOSTNAME}" ]; then
  if [ -z "${DEVICE}" ]; then
    echo "Error: no installation device specified"
  elif [ -z "${TARGET_HOSTNAME}" ]; then
    echo "Error: no target hostname specified"
  fi
  exit_usage
fi

if [[ ! ${ROOT_SIZE} =~ ^[0-9]+$ ]]; then
  "Error: invalid root size specified (${ROOT_SIZE})"
  exit_usage
fi
disk_size="$(($(blockdev --getsize64 "${DEVICE}")/1024/1024/1024 - 2))"
if [ "${ROOT_SIZE}" -gt "${disk_size}" ]; then
  echo -n "Error: root size bigger than the provided device, "
  echo     "please specify a smaller root size."
  exit_usage
fi

if [ "${USE_UEFI}" = true ] && [ ! -d "/sys/firmware/efi" ]; then
  echo    "ERROR: installing in UEFI mode but we are currently booted in legacy mode."
  echo    "Please check:"
  echo    "  1. That your BIOS is configured to boot using UEFI only."
  echo -n "  2. That the hard disk that you booted from (usb key or hard drive) "
  echo    "is using the GPT format and has a valid ESP."
  echo -n "And reboot the system in UEFI mode. "
  echo    "Alternatively you can run this installer in legacy mode."
  exit 1
fi

detect_swap="$(swapon | grep "${swapfile}" > /dev/null 2>&1; echo $?)"
if [ "${detect_swap}" -eq "0" ]; then
  swapoff "${swapfile}"
  rm --force "${swapfile}"
fi

MP=$(mountpoint --quiet /mnt/; echo $?) || true
if [ "${MP}" -eq "0" ]; then
  umount --recursive /mnt/
fi

cryptsetup close nixos_data_decrypted || true
vgremove --force LVMVolGroup || true
# We try both GPT and MBR style commands to wipe existing PVs.
# If the existing partition table is GPT, we use the partlabel
pvremove /dev/disk/by-partlabel/nixos_lvm || true
# If the existing partition table is MBR, we need to use direct addressing
pvremove "${DEVICE}2" || true

if [ "${USE_UEFI}" = true ]; then
  # Using zeroes for the start and end sectors, selects the default values, i.e.:
  #   the next unallocated sector for the start value
  #   the last sector of the device for the end value
  sgdisk --clear --mbrtogpt "${DEVICE}"
  sgdisk --new=1:2048:+512M --change-name=1:"efi"        --typecode=1:ef00 "${DEVICE}"
  sgdisk --new=2:0:+512M    --change-name=2:"nixos_boot" --typecode=2:8300 "${DEVICE}"
  sgdisk --new=3:0:0        --change-name=3:"nixos_lvm"  --typecode=3:8e00 "${DEVICE}"
  sgdisk --print "${DEVICE}"

  wait_for_devices "/dev/disk/by-partlabel/efi" \
                   "/dev/disk/by-partlabel/nixos_boot" \
                   "/dev/disk/by-partlabel/nixos_lvm"
else
  sfdisk --wipe            always \
         --wipe-partitions always \
         "${DEVICE}" \
<<EOF
label: dos
unit:  sectors

# Boot partition
type=83, start=2048, size=512MiB, bootable

# LVM partition, from first unallocated sector to end of disk
# These start and size values are the defaults when nothing is specified
type=8e
EOF
fi

if [ "${USE_UEFI}" = true ]; then
  BOOT_PART="/dev/disk/by-partlabel/nixos_boot"
  LVM_PART="/dev/disk/by-partlabel/nixos_lvm"
else
  BOOT_PART="${DEVICE}1"
  LVM_PART="${DEVICE}2"
fi

wait_for_devices "${LVM_PART}"
pvcreate "${LVM_PART}"
wait_for_devices "${LVM_PART}"
vgcreate LVMVolGroup "${LVM_PART}"
lvcreate --yes --size "${ROOT_SIZE}"GB --name nixos_root LVMVolGroup
wait_for_devices "/dev/LVMVolGroup/nixos_root"

if [ "${USE_UEFI}" = true ]; then
  wipefs --all /dev/disk/by-partlabel/efi
  mkfs.vfat -n EFI -F32 /dev/disk/by-partlabel/efi
fi
wipefs --all "${BOOT_PART}"
# We set the inode size to 256B for the boot partition.
# Small partitions default to 128B inodes but these cannot store dates
# beyond the year 2038.
mkfs.ext4 -e remount-ro -L nixos_boot -I 256 "${BOOT_PART}"
mkfs.ext4 -e remount-ro -L nixos_root /dev/LVMVolGroup/nixos_root

if [ "${USE_UEFI}" = true ]; then
  wait_for_devices "/dev/disk/by-label/EFI"
fi
wait_for_devices "/dev/disk/by-label/nixos_boot" \
                 "/dev/disk/by-label/nixos_root"

mount /dev/disk/by-label/nixos_root /mnt
mkdir --parents /mnt/boot
mount /dev/disk/by-label/nixos_boot /mnt/boot
if [ "${USE_UEFI}" = true ]; then
  mkdir --parents /mnt/boot/efi
  mount /dev/disk/by-label/EFI /mnt/boot/efi
fi

fallocate --length 4G "${swapfile}"
chmod 0600 "${swapfile}"
mkswap "${swapfile}"
swapon "${swapfile}"

# For the ISO, the nix store is mounted using tmpfs with default options,
# meaning that its size is limited to 50% of physical memory.
# On machines with low memory (< 8GB), this can cause issues.
# Now that we have created swap space above, and since we have ZRAM swap enabled,
# we can safely increase the size of the nix store for those machines.
total_mem=$(grep 'MemTotal:' /proc/meminfo | awk -F ' ' '{ print $2; }')
threshold_mem=$((8 * 1000 * 1000))
if [ "${total_mem}" -lt "${threshold_mem}" ]; then
  mount --options remount,size=4G /nix/.rw-store
fi

# We update the nix channel to make sure that we install up-to-date packages
echo "Updating the nix channel..."
nix-channel --update

if [ ! -f "/tmp/id_tunnel" ] || [ ! -f "/tmp/id_tunnel.pub" ]; then
  echo "Generating a new SSH key pair for this host..."
  ssh-keygen -a 100 \
             -t ed25519 \
             -N "" \
             -C "" \
             -f /tmp/id_tunnel
  echo "SSH keypair generated."
else
  # Make sure that we have the right permissions
  chmod 0400 /tmp/id_tunnel
fi

# Check whether we can authenticate to GitHub using this server's key.
# We run this part in a subshell, delimated by the parentheses, and in which we
# set +e, such that the installation script does not abort when the git command
# exits with a non-zero exit code.
(
  set +e

  function test_auth() {
    # Try to run a git command on the remote to test the authentication.
    # If this command exists with a zero exit code, then we have successfully
    # authenticated to GitHub.
    nix-shell --packages git \
              --run "git -c core.sshCommand='ssh -F none \
                                                 -o IdentitiesOnly=yes \
                                                 -i /tmp/id_tunnel' \
                         ls-remote ${config_repo} > /dev/null 2>&1"
  }

  echo "Trying to authenticate to GitHub..."
  test_auth
  can_authenticate="${?}"

  if [ "${can_authenticate}" -ne "0" ]; then
    echo -e "\nThis server's SSH key does not give us access to GitHub."
    echo    "Please add the following public key to the file"
    echo -e "json/tunnels.d/tunnels.json in the ${config_repo_name} repo:\n"
    cat /tmp/id_tunnel.pub
    echo -e "\nThe installation will automatically continue once the key"
    echo    "has been added to GitHub and the deployment actions have"
    echo    "completed."
    echo -e "\nIf you want me to generate a new key pair instead, then"
    echo    "remove /tmp/id_tunnel and /tmp/id_tunnel.pub and restart"
    echo    "the installer. You will then see this message again, and"
    echo -e "you will need to add the newly generated key to GitHub."
    echo -e "\nThe installer will continue once you have added the key"
    echo -e "to GitHub and the deployment actions have successfully run..."

    while [ "${can_authenticate}" -ne "0" ]; do
      sleep 5
      test_auth
      can_authenticate="${?}"
    done
  fi
  echo "Successfully authenticated to GitHub."
)

# Set some global Git settings
nix-shell --packages git \
          --run "git config --global pull.rebase true; \
                 git config --global user.name '${github_nixos_robot_name}'; \
                 git config --global user.email '${github_nixos_robot_email}'; \
                 git config --global core.sshCommand 'ssh -i /tmp/id_tunnel'"

# Commit a new encryption key to GitHub, if one does not exist yet
if [ "${CREATE_DATA_PART}" = true ]; then
  secrets_dir="${MSFOCB_SECRETS_DIRECTORY:-"/run/.secrets/"}"

  # Clean up potential left-over directories
  if [ -e "${nixos_dir}" ]; then
    rm --recursive --force "${nixos_dir}"
  fi
  if [ -e "${secrets_dir}" ]; then
    rm --recursive --force "${secrets_dir}"
  fi

  nix-shell --packages git \
            --run "git clone --filter=blob:none ${main_repo} ${nixos_dir}; \
                   git clone --filter=blob:none ${config_repo} ${config_dir}"

  function decrypt_secrets() {
    mkdir --parents "${secrets_dir}"
    nix-shell "${nixos_dir}"/scripts/python_nixostools/shell.nix \
              --run "decrypt_server_secrets \
                       --server_name ${TARGET_HOSTNAME} \
                       --secrets_path ${config_dir}/secrets/generated/generated-secrets.yml \
                       --output_path ${secrets_dir} \
                       --private_key_file /tmp/id_tunnel > /dev/null"
  }

  decrypt_secrets
  keyfile="${secrets_dir}/keyfile"
  if [ ! -f "${keyfile}" ]; then
    nix-shell "${nixos_dir}"/scripts/python_nixostools/shell.nix \
              --run "add_encryption_key \
                       --hostname ${TARGET_HOSTNAME} \
                       --secrets_file ${config_dir}/secrets/nixos_encryption-secrets.yml"

    random_id=$(tr --complement --delete A-Za-z0-9 < /dev/urandom | head --bytes=10)
    branch_name="installer_commit_enc_key_${TARGET_HOSTNAME}_${random_id}"
    nix-shell --packages git \
              --run "git -C ${config_dir} \
                         checkout -b ${branch_name}; \
                     git -C ${config_dir} \
                         add secrets/nixos_encryption-secrets.yml; \
                     git -C ${config_dir} \
                         commit \
                         --message 'Commit encryption key for ${TARGET_HOSTNAME}.'; \
                     git -C ${config_dir} \
                         push -u origin ${branch_name}"

    echo -e "\n\nThe encryption key for this server was committed to GitHub"
    echo -e "Please go to the following link to create a pull request:"
    echo -e "\nhttps://github.com/${github_org_name}/${config_repo_name}/pull/new/${branch_name}\n"
    echo -e "The installer will continue once the pull request has been merged into master."

    nix-shell --packages git \
              --run "git -C ${config_dir} checkout master"

    while [ ! -f "${keyfile}" ]; do
      nix-shell --packages git \
                --run "git -C ${config_dir} pull > /dev/null 2>&1"
      decrypt_secrets
      if [ ! -f "${keyfile}" ]; then
        sleep 10
      fi
    done
  fi
fi

# Now that the repos on GitHub should contain all the information,
# we throw away the clones we made so far and start over with clean ones.
rm --recursive --force /mnt/etc/
nix-shell --packages git \
          --run "git clone --filter=blob:none ${main_repo} ${nixos_dir}; \
                 git clone --filter=blob:none ${config_repo} ${config_dir}"
# Generate hardware-configuration.nix, but omit the filesystems which
# we already define statically in eval_host.nix.
nixos-generate-config --root /mnt --no-filesystems
# Create the settings.nix symlink pointing to the file defining the current server.
ln --symbolic org-config/hosts/"${TARGET_HOSTNAME}".nix \
              ${nixos_dir}/settings.nix
cp /tmp/id_tunnel /tmp/id_tunnel.pub ${nixos_dir}/local/

if [ "${CREATE_DATA_PART}" = true ]; then
  # Do this only after having generated the hardware config
  lvcreate --yes --extents 100%FREE --name nixos_data LVMVolGroup
  wait_for_devices "/dev/LVMVolGroup/nixos_data"

  mkdir --parents /run/cryptsetup
  cryptsetup --verbose \
             --batch-mode \
             --cipher aes-xts-plain64 \
             --key-size 512 \
             --hash sha512 \
             --use-urandom \
             luksFormat \
             --type luks2 \
             --key-file "${secrets_dir}/keyfile" \
             /dev/LVMVolGroup/nixos_data
  cryptsetup open \
             --key-file "${secrets_dir}/keyfile" \
             /dev/LVMVolGroup/nixos_data nixos_data_decrypted
  mkfs.ext4 -e remount-ro \
            -m 1 \
            -L nixos_data \
            /dev/mapper/nixos_data_decrypted

  wait_for_devices "/dev/disk/by-label/nixos_data"

  mkdir --parents /mnt/opt
  mount /dev/disk/by-label/nixos_data /mnt/opt
  mkdir --parents /mnt/home
  mkdir --parents /mnt/opt/.home
  mount --bind /mnt/opt/.home /mnt/home
fi

nixos-install --no-root-passwd --max-jobs 4

swapoff "${swapfile}"
rm --force "${swapfile}"

if [ "${CREATE_DATA_PART}" = true ]; then
  umount --recursive /mnt/home
  umount --recursive /mnt/opt
  cryptsetup close nixos_data_decrypted
fi

echo -e "\nNixOS installation finished, please reboot using \"sudo systemctl reboot\""

