{
  description = "DMS Sessionizer — Dux Shell (DMS) launcher plugin";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      manifest = builtins.fromJSON (builtins.readFile ./plugin.json);
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.stdenvNoCC.mkDerivation {
            pname = "dms-plugin-${manifest.id}";
            version = manifest.version;
            src = self;
            dontConfigure = true;
            dontBuild = true;
            installPhase = ''
              runHook preInstall
              mkdir -p $out
              cp -r assets dmsSessionizer.qml dmsSessionizerSettings.qml \
                LICENSE plugin.json README.md $out/
              runHook postInstall
            '';
            meta = {
              description = manifest.description;
              homepage = "https://github.com/leonardofranco01/dms-sessionizer";
              platforms = pkgs.lib.platforms.all;
            };
          };
        }
      );
    };
}
