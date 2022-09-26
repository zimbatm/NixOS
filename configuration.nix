# By default we import the settings.nix file which points to the host file for
# the current server.
{
  imports = [
    (import ./eval_host.nix {
      host_config = {
        imports = [
          ./settings.nix
          ./hardware-configuration.nix
        ];
      };
    })
  ];
}

