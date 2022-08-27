{ config, lib, pkgs, ... }:

with lib;

let
  inherit (config.lib) ext_lib;

  cfg = config.settings.services.traefik;
  system_cfg = config.settings.system;
  docker_cfg = config.settings.docker;

  # Formatter for YAML
  yaml_format = pkgs.formats.yaml { };
in

{

  options.settings.services.traefik =
    let
      tls_entrypoint_opts = { name, ... }: {
        options = {
          name = mkOption {
            type = types.str;
          };

          enable = mkEnableOption "the user";

          host = mkOption {
            type = types.str;
            default = "";
          };

          port = mkOption {
            type = types.port;
          };

        };
        config = {
          name = mkDefault name;
        };
      };
    in
    {
      enable = mkEnableOption "the Traefik service";

      version = mkOption {
        type = types.str;
        default = "latest";
      };

      image = mkOption {
        type = types.str;
        default = "traefik";
        readOnly = true;
      };

      service_name = mkOption {
        type = types.str;
        default = "nixos-traefik";
        readOnly = true;
      };

      dynamic_config = mkOption {
        type = with types; attrsOf (submodule {
          options = {
            enable = mkOption {
              type = types.bool;
              default = true;
            };
            value = mkOption {
              type = yaml_format.type;
            };
          };
        });
      };

      tls_entrypoints = mkOption {
        type = with types; attrsOf (submodule tls_entrypoint_opts);
        default = { };
      };

      network_name = mkOption {
        type = types.str;
        default = "web";
      };

      logging_level = mkOption {
        type = types.enum [ "INFO" "DEBUG" "TRACE" ];
        default = "INFO";
      };

      accesslog = {
        enable = mkOption {
          type = types.bool;
          default = true;
        };
      };

      traefik_entrypoint_port = mkOption {
        type = types.port;
        default = 8080;
      };

      content_type_nosniff_enable = mkOption {
        type = types.bool;
        default = true;
      };

      acme = {
        staging = {
          enable = mkEnableOption "the Let's Encrypt staging environment";

          caserver = mkOption {
            type = types.str;
            default = "http://acme-staging-v02.api.letsencrypt.org/directory";
            readOnly = true;
          };
        };

        crossSignedChain = {
          enable = mkEnableOption "the Let's Encrypt cross-signed certificate chain";

          preferredChain = mkOption {
            type = types.str;
            default = "DST Root CA X3";
            readOnly = true;
            description = ''
              The Common Name (CN) of the root certificate to anchor the chain on.
            '';
          };
        };

        keytype = mkOption {
          type = types.str;
          default = "EC256";
          readOnly = true;
        };

        storage = mkOption {
          type = types.str;
          default = "/letsencrypt";
          readOnly = true;
        };

        email_address = mkOption {
          type = types.str;
        };

        dns_providers = mkOption {
          type = with types; attrsOf str;
          default = { azure = "azure"; route53 = "route53"; };
          readOnly = true;
        };

        dns_provider = mkOption {
          type = types.enum (attrValues cfg.acme.dns_providers);
        };
      };
    };

  config =
    let
      security-headers = "security-headers";
      extra-security-headers = "extra-security-headers";
      hsts-headers = "hsts-headers";
      compress-middleware = "compress-middleware";
      autodetect-middleware = "autodetect-middleware";
      default-middleware = "default-middleware";
      default-ssl-middleware = "default-ssl-middleware";
      # https://github.com/traefik/traefik/issues/6636
      dashboard-middleware = "dashboard-middleware";
    in
    mkIf cfg.enable {

      settings = {
        docker.enable = true;

        services.traefik = {
          dynamic_config.default_config = {
            enable = true;
            value = {
              http = {
                routers.dashboard = {
                  entryPoints = [ "traefik" ];
                  rule = "PathPrefix(`/api`) || PathPrefix(`/dashboard`)";
                  service = "api@internal";
                };

                middlewares =
                  let
                    content_type = optionalAttrs cfg.content_type_nosniff_enable {
                      contentTypeNosniff = true;
                    };
                  in
                  {
                    ${default-ssl-middleware}.chain.middlewares = [
                      "${hsts-headers}@file"
                      "${default-middleware}@file"
                    ];
                    ${default-middleware}.chain.middlewares = [
                      "${security-headers}@file"
                      "${compress-middleware}@file"
                      "${autodetect-middleware}@file"
                    ];
                    ${dashboard-middleware}.chain.middlewares = [
                      "${security-headers}@file"
                      "${compress-middleware}@file"
                    ];
                    ${security-headers}.headers = {
                      referrerPolicy = "no-referrer, strict-origin-when-cross-origin";
                      customFrameOptionsValue = "SAMEORIGIN";
                      customResponseHeaders = {
                        Expect-CT = "max-age=${toString (24 * 60 * 60)}, enforce";
                        Server = "";
                        X-Generator = "";
                        X-Powered-By = "";
                        X-AspNet-Version = "";
                      };
                    };
                    #${extra-security-headers}.headers = content_type;
                    ${hsts-headers}.headers = {
                      stsPreload = true;
                      stsSeconds = toString (365 * 24 * 60 * 60);
                      stsIncludeSubdomains = true;
                    };
                    ${compress-middleware}.compress = { };
                    ${autodetect-middleware}.contentType.autoDetect = false;
                  };
              };

              tls.options.default = {
                minVersion = "VersionTLS12";
                sniStrict = true;
                cipherSuites = [
                  # https://godoc.org/crypto/tls#pkg-constants
                  # TLS 1.2
                  "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384"
                  "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256"
                  "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384"
                  "TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256"
                  # TLS 1.3
                  "TLS_AES_256_GCM_SHA384"
                  "TLS_CHACHA20_POLY1305_SHA256"
                ];
              };
            };
          };
        };
      };

      virtualisation.oci-containers = {
        backend = "docker";
        containers =
          let
            static_config_file_name = "traefik-static.yml";
            static_config_file_target = "/${static_config_file_name}";
            dynamic_config_directory_name = "traefik-dynamic.conf.d";
            dynamic_config_directory_target = "/${dynamic_config_directory_name}";

            static_config_file_source =
              let
                generate_tls_entrypoints = ext_lib.compose [
                  (mapAttrs (_: value: { address = "${value.host}:${toString value.port}"; }))
                  ext_lib.filterEnabled
                ];
                letsencrypt = "letsencrypt";
                caserver = optionalAttrs cfg.acme.staging.enable
                  { inherit (cfg.acme.staging) caserver; };
                preferredChain = optionalAttrs cfg.acme.crossSignedChain.enable
                  { inherit (cfg.acme.crossSignedChain) preferredChain; };
                acme_template = {
                  email = cfg.acme.email_address;
                  storage = "${cfg.acme.storage}/acme.json";
                  keyType = cfg.acme.keytype;
                } // caserver
                // preferredChain;
                accesslog = optionalAttrs cfg.accesslog.enable {
                  accessLog = {
                    # Make sure that the times are printed in local time
                    # https://doc.traefik.io/traefik/observability/access-logs/#time-zones
                    fields = {
                      names.StartUTC = "drop";
                      headers.names.User-Agent = "keep";
                    };
                  };
                };
                static_config = {
                  global.sendAnonymousUsage = true;
                  ping = { };
                  log.level = cfg.logging_level;
                  api.dashboard = true;
                  #metrics:
                  #  prometheus: {}

                  providers = {
                    docker = {
                      network = cfg.network_name;
                      swarmMode = docker_cfg.swarm.enable;
                      exposedbydefault = false;
                    };
                    file = {
                      watch = true;
                      directory = dynamic_config_directory_target;
                    };
                  };

                  entryPoints = {
                    web = {
                      address = ":80";
                      http = {
                        redirections.entryPoint = {
                          to = "websecure";
                          scheme = "https";
                        };
                        middlewares = [ "${default-middleware}@file" ];
                      };
                    };
                    websecure = {
                      address = ":443";
                      http = {
                        middlewares = [ "${default-ssl-middleware}@file" ];
                        tls.certResolver = letsencrypt;
                      };
                      http3 = { };
                    };
                    traefik = {
                      address = ":${toString cfg.traefik_entrypoint_port}";
                      http.middlewares = [ "${dashboard-middleware}@file" ];
                    };
                  } // generate_tls_entrypoints cfg.tls_entrypoints;

                  experimental.http3 = true;

                  certificatesresolvers = {
                    ${letsencrypt}.acme =
                      acme_template // {
                        httpChallenge.entryPoint = "web";
                      };
                    "${letsencrypt}_dns".acme =
                      acme_template // {
                        dnsChallenge = {
                          resolvers = [
                            "9.9.9.9:53"
                            "8.8.8.8:53"
                            "1.1.1.1:53"
                          ];
                          provider = cfg.acme.dns_provider;
                        };
                      };
                  };
                } // accesslog;
              in
              yaml_format.generate static_config_file_name static_config;

            dynamic_config_mounts =
              let
                buildConfigFile = key: configFile:
                  let
                    name = "${key}.yml";
                    file = yaml_format.generate name configFile.value;
                  in
                  "${file}:${dynamic_config_directory_target}/${name}:ro";
                buildConfigFiles = mapAttrsToList buildConfigFile;
              in
              ext_lib.compose [
                buildConfigFiles
                ext_lib.filterEnabled
              ]
                cfg.dynamic_config;

          in
          {
            "${cfg.service_name}" = {
              image = "${cfg.image}:${cfg.version}";
              cmd = [
                "--configfile=${static_config_file_target}"
              ];
              ports =
                let
                  traefik_entrypoint_port_str = toString cfg.traefik_entrypoint_port;
                  mk_tls_port = cfg:
                    let
                      port = toString cfg.port;
                    in
                    "${port}:${port}";
                  mk_tls_ports = mapAttrsToList (_: mk_tls_port);
                in
                [
                  "80:80"
                  "443:443/tcp"
                  "443:443/udp"
                  "127.0.0.1:${traefik_entrypoint_port_str}:${traefik_entrypoint_port_str}"
                  "[::1]:${traefik_entrypoint_port_str}:${traefik_entrypoint_port_str}"
                ] ++ mk_tls_ports cfg.tls_entrypoints;
              volumes = [
                "/etc/localtime:/etc/localtime:ro"
                "/var/run/docker.sock:/var/run/docker.sock:ro"
                "${static_config_file_source}:${static_config_file_target}:ro"
                "traefik_letsencrypt:${cfg.acme.storage}"
              ] ++ dynamic_config_mounts;
              workdir = "/";
              extraOptions = [
                # Make Lego resolve CNAMEs when creating DNS records
                # to perform Let's Encrypt DNS challenges
                "--env=LEGO_EXPERIMENTAL_CNAME_SUPPORT=true"
                # AWS route53 DNS zone credentials,
                # these can be loaded through an env file, see below
                "--env=AWS_ACCESS_KEY_ID"
                "--env=AWS_SECRET_ACCESS_KEY"
                "--env=AWS_HOSTED_ZONE_ID"

                "--network=${cfg.network_name}"
                "--tmpfs=/tmp:rw,nodev,nosuid,noexec"
                "--tmpfs=/run:rw,nodev,nosuid,noexec"
                "--health-cmd=traefik healthcheck --ping"
                "--health-interval=60s"
                "--health-retries=3"
                "--health-timeout=3s"
              ];
            };
          };
      };

      systemd.services =
        let
          docker = "${pkgs.docker}/bin/docker";
          systemctl = "${pkgs.systemd}/bin/systemctl";
          traefik_docker_service_name = "docker-${cfg.service_name}";
          traefik_docker_service = "${traefik_docker_service_name}.service";
        in
        {
          # We slightly adapt the generated service for Traefik
          "${traefik_docker_service_name}" =
            let
              dns_credentials_file = system_cfg.secrets.dest_directory + cfg.acme.dns_provider;
            in
            {
              # Requires needs to be accompanied by an After condition in order to be effective
              # See https://www.freedesktop.org/software/systemd/man/systemd.unit.html#Requires=
              requires = [ "docker.service" ];
              after = [ "docker.service" ];
              wantedBy = [ "docker.service" ];
              serviceConfig = {
                # Restore the defaults to have proper logging in the systemd journal.
                # See GitHub NixOS/nixpkgs issue #102768 and PR #102769
                # https://github.com/NixOS/nixpkgs/issues/102768
                # https://github.com/NixOS/nixpkgs/pull/102769
                StandardOutput = mkForce "journal";
                StandardError = mkForce "inherit";

                # The preceding "-" means that non-existing files will be ignored
                # See https://www.freedesktop.org/software/systemd/man/systemd.exec#EnvironmentFile=
                EnvironmentFile = "-${dns_credentials_file}";
              };
              # Create the Traefik docker network in advance if it does not exist yet
              preStart = ''
                if [ -z $(${docker} network list --filter "name=^${cfg.network_name}$" --quiet) ]; then
                  ${docker} network create ${cfg.network_name}
                fi
              '';
            };

          "${traefik_docker_service_name}-pull" = {
            inherit (cfg) enable;
            description = "Automatically pull the latest version of the Traefik image";
            serviceConfig = {
              Type = "oneshot";
            };
            script = ''
              ${docker} pull ${cfg.image}:${cfg.version}
              ${systemctl} try-restart ${traefik_docker_service}
              prev_images="$(${docker} image ls \
                --quiet \
                --filter 'reference=${cfg.image}' \
                --filter 'before=${cfg.image}:${cfg.version}')"
              if [ ! -z "''${prev_images}" ]; then
                ${docker} image rm ''${prev_images}
              fi
            '';
            startAt = "Wed 03:00";
          };
        };
    };
}

