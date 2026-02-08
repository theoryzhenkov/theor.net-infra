{
  description = "NixOS configuration for theor.net Hetzner server";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, disko, sops-nix, deploy-rs }: 
  let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-darwin" "x86_64-darwin" "aarch64-linux" ];
  in {
    devShells = forAllSystems (system: {
      default = nixpkgs.legacyPackages.${system}.mkShell {
        packages = with nixpkgs.legacyPackages.${system}; [
          sops
          age
          ssh-to-age
          just
        ] ++ [
          deploy-rs.packages.${system}.deploy-rs
        ];
      };
    });

    nixosConfigurations.theor-net-web = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        disko.nixosModules.disko
        sops-nix.nixosModules.sops
        ./disk-config.nix
        ./hardware-configuration.nix
        ./configuration.nix
      ];
    };

    deploy.nodes.theor-net-web = {
      hostname = "theor-net-web";
      sshUser = "root";
      sshOpts = [ "-A" ];
      profiles.system = {
        user = "root";
        path = deploy-rs.lib.x86_64-linux.activate.nixos
          self.nixosConfigurations.theor-net-web;
      };
    };
  };
}