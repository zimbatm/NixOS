{ pkgs, lib, ... }:

{
  nix = {
    binaryCaches = [
      "https://msf-ocb.cachix.org"
    ];
    binaryCachePublicKeys = [
      "msf-ocb.cachix.org-1:scW00fEiHmTt4Ig9BzZyaBBym+eHAC3ffDUYrh5Oo4g="
    ];
  };
}
