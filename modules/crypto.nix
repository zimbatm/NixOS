{ config, lib, pkgs, ... }:

with lib;

let
  inherit (config.lib) ext_lib;

  cfg = config.settings.crypto;
  sys_cfg = config.settings.system;

  cryptoOpts = { name, config, ... }: {
    options = {
      enable = mkEnableOption "the encrypted device";

      name = mkOption {
        type = types.strMatching "^[[:lower:]][-_[:lower:]]+[[:lower:]]$";
      };

      device = mkOption {
        type = types.str;
        example = "/dev/LVMVolGroup/nixos_data";
        description = "The device to mount.";
      };

      device_units = mkOption {
        type = with types; listOf str;
        default = [ ];
        example = [ "dev-disk-by\\x2did-dm\\x2dname\\x2dLVMVolGroup\\x2dnixos_data.device" ];
        description = "Device units to wait for or be triggered by.";
      };

      key_file = mkOption {
        type = types.str;
        default = "${sys_cfg.secrets.dest_directory}/keyfile";
        # We currently do not have multiple key files on any server and
        # we first need to migrate to properly secured key files.
        readOnly = true;
      };

      mount_point = mkOption {
        type = types.strMatching "^(/[-_[:lower:]]*)+$";
        description = ''
          The mount point on which to mount the partition contained
          in this encrypted volume.
          Currently we assume that every encrypted volume, contains
          a single partition, but this assumption could be generalised.
        '';
      };

      filesystem_type = mkOption {
        type = types.str;
        default = "ext4";
      };

      mount_options = mkOption {
        type = types.str;
        default = "";
        example = "acl,noatime,nosuid,nodev";
      };

      dependent_services = mkOption {
        type = with types; listOf (strMatching "^[-_[:upper:][:lower:]]*\\.service$");
        example = [ "docker.service" "docker-registry.service" ];
        default = [ ];
      };

    };

    config = {
      name = mkDefault name;
    };
  };
in
{

  options.settings.crypto = {
    mounts = mkOption {
      type = with types; attrsOf (submodule cryptoOpts);
      default = [ ];
    };

    encrypted_opt = {
      enable = mkEnableOption "the encrypted /opt partition";

      device = mkOption {
        type = types.str;
        default = "/dev/LVMVolGroup/nixos_data";
        description = "The device to mount on /opt.";
      };
    };
  };

  imports = [
    (mkRenamedOptionModule [ "settings" "crypto" "enable" ] [ "settings" "crypto" "encrypted_opt" "enable" ])
    (mkRenamedOptionModule [ "settings" "crypto" "device" ] [ "settings" "crypto" "encrypted_opt" "device" ])
  ];

  config =
    let
      decrypted_name = conf: "nixos_decrypted_${conf.name}";
      open_service_name = conf: "open_encrypted_${conf.name}";

      mkOpenService = conf: {
        enable = conf.enable;
        description = "Open the encrypted ${conf.name} partition.";
        conflicts = [ "shutdown.target" ];
        before = [ "shutdown.target" ];
        after = conf.device_units;
        wantedBy = conf.device_units;
        requires = conf.device_units;
        restartIfChanged = false;
        unitConfig = {
          DefaultDependencies = "no";
          ConditionPathExists = "!/dev/mapper/${decrypted_name conf}";
        };
        serviceConfig = {
          User = "root";
          Type = "oneshot";
          Restart = "on-failure";
          RemainAfterExit = true;
          ExecStop = ''
            ${pkgs.cryptsetup}/bin/cryptsetup close --deferred ${decrypted_name conf}
          '';
        };
        script = ''
          function test_passphrase() {
            ${pkgs.cryptsetup}/bin/cryptsetup luksOpen \
                                              --test-passphrase \
                                              ${conf.device} \
                                              --key-file "''${1}" \
                                              > /dev/null 2>&1
            echo "''${?}"
          }

          # Avoid a harmless warning
          mkdir --parents /run/cryptsetup

          # Add the new key if both the new and the old exist
          if [ -e "${conf.key_file}" ] && [ -e "/keyfile" ]; then
            new_key_test="$(test_passphrase ${conf.key_file})"
            if [ "''${new_key_test}" -ne 0 ]; then
              echo "Adding key ${conf.key_file} to ${conf.device}..."
              ${pkgs.cryptsetup}/bin/cryptsetup luksAddKey \
                                                ${conf.device} \
                                                --key-file /keyfile \
                                                ${conf.key_file}
            fi
          fi

          # Determine the key file to use to open the partition
          if [ -e "${conf.key_file}" ]; then
            keyfile="${conf.key_file}"
          elif [ -e "/keyfile" ]; then
            keyfile="/keyfile"
          else
            echo "Keyfile ('${conf.key_file}') not found!"
            exit 1
          fi

          echo "Unlocking ${conf.device} using key ''${keyfile}..."

          ${pkgs.cryptsetup}/bin/cryptsetup open \
                                            ${conf.device} \
                                            ${decrypted_name conf} \
                                            --key-file ''${keyfile}

          # We remove the old key from the partition if the new one has been added
          if [ -e "${conf.key_file}" ] && [ -e "/keyfile" ]; then
            new_key_test="$(test_passphrase ${conf.key_file})"
            old_key_test="$(test_passphrase /keyfile)"
            if [ "''${new_key_test}" -eq 0 ] && [ "''${old_key_test}" -eq 0 ]; then
              echo "Removing /keyfile from ${conf.device}..."
              ${pkgs.cryptsetup}/bin/cryptsetup luksRemoveKey \
                                                ${conf.device} \
                                                --key-file /keyfile
            fi
          fi

          # We wait to exit from this script until
          # the decrypted device has been created by udev
          dev="/dev/mapper/${decrypted_name conf}"
          echo "Making sure that ''${dev} exists before exiting..."
          for countdown in $( seq 60 -1 0 ); do
            if [ -b "''${dev}" ]; then
              exit 0
            fi
            echo "Waiting for ''${dev}... (''${countdown})"
            sleep 5
            udevadm settle --exit-if-exists="''${dev}"
          done
          echo "Device node could not be found, exiting..."
          exit 1
        '';
      };
      mkMount = conf: {
        enable = conf.enable;
        #TODO generalise, should we specify the partitions separately?
        what = "/dev/mapper/${decrypted_name conf}";
        where = conf.mount_point;
        type = conf.filesystem_type;
        options = conf.mount_options;
        after = [ "${open_service_name conf}.service" ];
        requires = [ "${open_service_name conf}.service" ];
        wantedBy = [
          "multi-user.target"
          "${open_service_name conf}.service"
        ];
        before = conf.dependent_services;
        requiredBy = conf.dependent_services;
      };

      mkOpenServices = mapAttrs' (_: conf: nameValuePair (open_service_name conf)
        (mkOpenService conf));
      mkMounts = mapAttrsToList (_: conf: mkMount conf);
    in
    {
      settings.crypto.mounts = {
        opt = mkIf cfg.encrypted_opt.enable {
          enable = true;
          device = cfg.encrypted_opt.device;
          mount_point = "/opt";
          mount_options = "acl,noatime,nosuid,nodev";
          # When /opt is a separate partition, it needs to be mounted before starting docker and docker-registry.
          dependent_services = (optional config.virtualisation.docker.enable "docker.service") ++
            (optional config.services.dockerRegistry.enable "docker-registry.service");
        };
      };
      systemd =
        let
          enabled = ext_lib.filterEnabled cfg.mounts;
          extra_mount_units = optional cfg.encrypted_opt.enable {
            enable = cfg.encrypted_opt.enable;
            what = "/opt/.home";
            where = "/home";
            type = "none";
            options = "bind";
            after = [ "opt.mount" ];
            requires = [ "opt.mount" ];
            wantedBy = [ "multi-user.target" ];
          };
        in
        {
          services = mkOpenServices enabled;
          mounts = mkMounts enabled ++ extra_mount_units;
        };
    };
}

