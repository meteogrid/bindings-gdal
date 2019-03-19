let
  pkgs = import ./nixpkgs.nix;

  haskellPackages = pkgs.haskellPackages.override {
    overrides = self: super: with pkgs.haskell.lib; {
      resourcet = super.resourcet_1_1_11;
      conduit = super.conduit_1_2_13_1;
    };
  };

  # gdal 2.4 generates failures
  gdal_2_3_0 = pkgs.callPackage (pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/NixOS/nixpkgs/17ccab6b124183b90d4c5fd2c7252024ae10c978/pkgs/development/libraries/gdal/default.nix";
    sha256 = "07v8yygk16a19p0rd4nlqvrl4bvcpb885l9c1vp8k45m9hdk48z7";
  }) {
      poppler = pkgs.poppler_0_61;
  };

  withGdal = gdal: haskellPackages.callCabal2nixWithOptions "bindings-gdal" (pkgs.lib.sources.cleanSource ./.)  "-f -autoconfig" { inherit gdal; };

  jobs = rec {
    bindings-gdal = withGdal gdal_2_3_0;
    bindings-gdal_1_11 = withGdal pkgs.gdal_1_11;
  };
in
  jobs
