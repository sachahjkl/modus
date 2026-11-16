{
  description = "A fast, modular operating system, sandboxed by default";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.2605";
    git-hooks = {
      url = "https://flakehub.com/f/cachix/git-hooks.nix/0.1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs: let
    # The first machine is x86-64 under QEMU. The build host is the same.
    system = "x86_64-linux";
    pkgs = inputs.nixpkgs.legacyPackages.${system};

    # LLVM 18, the LLVM of the Odin compiler, with one commit of LLVM 21.
    # Dead store elimination of LLVM 18 shortens the stores that a later
    # store overwrites in part, in the order of a hash table keyed by the
    # addresses of the instructions in memory. The compiler allocates on
    # several threads, so those addresses change from one build to the next. With
    # debug information, each shortened store adds a debug record after a
    # shared one, so the records came in another order at each build, and
    # the LLVM IR and the object of a module were not the same bytes twice.
    # The commit keeps the order of insertion. It changes no instruction
    # (docs/REPRODUCIBLE_BUILD.md, "9. The order of dead store elimination").
    # No binary cache has this build: a machine builds LLVM once.
    llvm = pkgs.llvmPackages_18.llvm.overrideAttrs (old: {
      patches =
        old.patches
        ++ [
          (pkgs.fetchpatch {
            name = "llvm-dead-store-elimination-deterministic-order.patch";
            url = "https://github.com/llvm/llvm-project/commit/c833746c6c062677a040d18d837c7fad71939171.patch";
            relative = "llvm";
            hash = "sha256-AW11MQuxd82OLePO/x7vBnE/ozUD4qUjoF3cZQ1tE7A=";
          })
        ];
      # The tests of LLVM take longer than its build. The commit is tested
      # upstream, and the full check of the system builds every module.
      doCheck = false;
    });

    # The release of Odin is pinned here, not by Nixpkgs: Nixpkgs is months
    # behind the releases of the compiler. It links the LLVM above.
    odinRelease = "dev-2026-11a";
    odin = (pkgs.odin.override {llvmPackages_18 = pkgs.llvmPackages_18 // {inherit llvm;};}).overrideAttrs (_: {
      version = odinRelease;
      src = pkgs.fetchFromGitHub {
        # The fork of this system: the release above and the option
        # `-debug-info:same-code`, a kind of debug information that never
        # changes the code (docs/REPRODUCIBLE_BUILD.md, section 8). With
        # no such option the fork is the release. The branch is
        # `odin-modus-same-code`; the commit is pinned.
        owner = "sachahjkl";
        repo = "Odin";
        rev = "81382db6047ac43a2d397046fa45f253aa628f7c";
        hash = "sha256-zIwSlShXOefc55xmDXY8aYBCRegVdrRIOuMzXQCClKw=";
      };
      # No patch file: the changes are commits of the fork. The patches of
      # Nixpkgs are for raylib and for Darwin, which this system does not use.
      patches = [];
      postPatch = "patchShebangs --build build_odin.sh";
      # The compiler and its base and core libraries only: no vendor library
      # is built, because no code of this system imports one.
      installPhase = ''
        runHook preInstall
        mkdir -p $out/bin $out/share
        cp odin $out/bin/odin
        cp -r base core $out/share
        wrapProgram $out/bin/odin \
          --prefix PATH : ${pkgs.lib.makeBinPath ([llvm] ++ (with pkgs.llvmPackages_18; [bintools clang lld]))} \
          --set-default ODIN_ROOT $out/share
        runHook postInstall
      '';
    });

    # What tools/modustool needs on the path.
    # llc comes from the LLVM of the Odin compiler (18): Odin writes LLVM IR, and
    # llc makes each object with frame pointers.
    # openssl: its QUIC client is the peer of the test "quic-real" of modustool.
    # swtpm: the software TPM of the machines of "test trusted_boot".
    # sbsigntool (sbsign): signs the boot program for Secure Boot.
    # virt-firmware (virt-fw-vars): enrols the certificate of the firmware
    # signing key in a variable store of the firmware, with Secure Boot on.
    # openssl also makes the firmware signing key ("modustool key new").
    # zstd: compresses the release image ("modustool release image") and
    # decompresses it for its machine of "test trusted_boot".
    buildTools = [odin llvm pkgs.llvmPackages.lld pkgs.nasm pkgs.qemu pkgs.coreutils pkgs.openssl pkgs.swtpm pkgs.sbsigntool pkgs.python3Packages.virt-firmware pkgs.zstd];

    # The pointer theme of the owner (docs/POINTERS.md): "Posy's Cursor", the
    # package of nixpkgs, pinned by flake.lock. Its license is CC-BY-NC-4.0,
    # which nixpkgs marks unfree and not redistributable: this one package is
    # allowed by its name. The repository holds no file of the theme: the
    # tool converts it at each build into build/pointers.
    pointerTheme =
      (import inputs.nixpkgs {
        inherit system;
        config.allowUnfreePredicate = package: inputs.nixpkgs.lib.getName package == "posy-cursors";
      }).posy-cursors;

    # The firmware of the machines of the measure: the TPM driver without
    # Secure Boot, so without system management mode. With it, the firmware
    # sometimes abandons one command of the software TPM and stops using the
    # TPM for the rest of the boot (docs/TRUSTED_BOOT.md, "The machines of
    # the TPM").
    ovmfWithTpm = pkgs.OVMF.override {tpmSupport = true;};

    # The UEFI firmware of the first machine. modustool reads these names.
    firmware = {
      OVMF_CODE = "${pkgs.OVMF.fd}/FV/OVMF_CODE.fd";
      OVMF_VARS = "${pkgs.OVMF.fd}/FV/OVMF_VARS.fd";
      # The same firmware with a TPM driver and no system management mode,
      # for the machines of the measure. Nixpkgs builds no such variant: this
      # one is built from the source of EDK II, once, then kept in the store.
      OVMF_TPM_CODE = "${ovmfWithTpm.fd}/FV/OVMF_CODE.fd";
      OVMF_TPM_VARS = "${ovmfWithTpm.fd}/FV/OVMF_VARS.fd";
      # The firmware with a TPM driver and Secure Boot (it needs the system
      # management mode of QEMU), for the machines of Secure Boot. Its
      # variable store has no key; the build writes a copy with the
      # certificate of the firmware signing key enrolled and Secure Boot on.
      OVMF_FULL_CODE = "${pkgs.OVMFFull.fd}/FV/OVMF_CODE.fd";
      OVMF_FULL_VARS = "${pkgs.OVMFFull.fd}/FV/OVMF_VARS.fd";
      # The source of the font, for the command "font" of modustool.
      FONT_SOURCE = "${pkgs.spleen}/share/fonts/misc/spleen-8x16.bdf";
      # The Xcursor folder of the pointer theme of the owner, for the build.
      POINTER_THEME_SOURCE = "${pointerTheme}/share/icons/Posy_Cursor/cursors";
    };

    # The vector font candidates, for the command "vector_fonts" of modustool
    # (docs/FONTS.md): name=file, separated by ";". Only the development shell
    # has them: the build reads the subsets in resources/fonts.
    # Paper Mono is not in nixpkgs: its two files come from its repository,
    # at one commit, each checked by its hash.
    paperMonoFile = name: hash:
      pkgs.fetchurl {
        url = "https://raw.githubusercontent.com/paper-design/paper-mono/74fc5537cc1f7b39aa8cccfa7dd3822e17143cca/fonts/ttf/${name}";
        inherit hash;
      };
    # B612, the interface font (docs/FONTS.md, section 12): from its
    # repository, at one commit, each file checked by its hash.
    b612File = name: hash:
      pkgs.fetchurl {
        url = "https://raw.githubusercontent.com/polarsys/b612/48ac6ba67ecab8123e8e36d6aa05367db0c7b638/fonts/ttf/${name}";
        inherit hash;
      };
    vectorFontSources = {
      VECTOR_FONT_SOURCES = builtins.concatStringsSep ";" [
        "paper_mono=${paperMonoFile "PaperMono-Regular.ttf" "sha256-Ew4aCbZLTxUNNMk6a3vVLWxcNRN2HR+8e+QtaDmLjBA="}"
        "paper_mono_semibold=${paperMonoFile "PaperMono-SemiBold.ttf" "sha256-Gx5gctnLUz5DBacHayRKoSEnElaJyTSf25d1c6Naxl4="}"
        "dejavu_sans_mono=${pkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSansMono.ttf"
        "jetbrains_mono=${pkgs.jetbrains-mono}/share/fonts/truetype/JetBrainsMono-Regular.ttf"
        "ibm_mono=${pkgs.ibm-plex}/share/fonts/truetype/IBMPlexMono-Regular.ttf"
        "fira_mono=${pkgs.fira-mono}/share/fonts/truetype/FiraMono-Regular.ttf"
        "commit_mono=${pkgs.commit-mono}/share/fonts/truetype/CommitMono-400-Regular.ttf"
        "iosevka=${pkgs.iosevka-bin}/share/fonts/truetype/Iosevka-Regular.ttc"
        "b612=${b612File "B612-Regular.ttf" "sha256-E53OZZEAqDv5W0hHRpbkSL7pVjHvhP09BDfO0r8zz3M="}"
        "b612_bold=${b612File "B612-Bold.ttf" "sha256-kXSVQax7LDKLWIMrfixN+AnX4ro41io6WqP444snGBQ="}"
      ];
    };

    preCommitCheck = inputs.git-hooks.lib.${system}.run {
      package = pkgs.prek;
      src = ./.;
      hooks = {
        alejandra.enable = true;
        deadnix.enable = true;
        statix.enable = true;
        check-merge-conflicts.enable = true;
      };
    };

    # The command "modustool": it compiles tools/modustool with the source
    # library of the project, and runs it in the folder of the project.
    # With MODUS_SYSTEM set, the folder of the project is that folder and
    # the command runs where it is typed: the folder of another project,
    # for the command "module-build"
    # (docs/TOOLS.md, "A module from a source outside the repository").
    modustool = pkgs.writeShellScriptBin "modustool" ''
      if [ -n "''${MODUS_SYSTEM:-}" ]; then
        mkdir -p "$MODUS_SYSTEM/build"
        # The tool compiles in the folder of the system: a source of the
        # tool includes an assembly file by a path from that folder.
        (cd "$MODUS_SYSTEM" && odin build tools/modustool -vet -collection:modus=src/library -out:build/modustool) || exit 1
        exec "$MODUS_SYSTEM/build/modustool" "$@"
      fi
      mkdir -p build
      exec odin run tools/modustool -vet -collection:modus=src/library -out:build/modustool -- "$@"
    '';

    # modustool check: the host code passes -vet and its tests, the system builds,
    # and the machine test passes under QEMU (console, desktop, tools).
    bootTest = pkgs.stdenvNoCC.mkDerivation ({
        name = "kernel-boot-test";
        src = inputs.nixpkgs.lib.fileset.toSource {
          root = ./.;
          # The host tests of `modustool site` read README.md, flake.lock and the Markdown documents; the check of the source paths in the documents reads AGENTS.md too; the check of the README needs its pictures; `modustool news check` reads news/, and the film that a news entry names (docs/films: absent in a tree where no entry names a film); the check of the font of the name of the mark reads LICENSE, whose text the font carries.
          fileset = inputs.nixpkgs.lib.fileset.unions [./flake.nix ./flake.lock ./CHANGELOG.md ./ROADMAP.md ./changelog.d ./news ./README.md ./AGENTS.md ./LICENSE (inputs.nixpkgs.lib.fileset.fileFilter (file: file.hasExt "md") ./docs) ./docs/screenshots (inputs.nixpkgs.lib.fileset.maybeMissing ./docs/films) ./resources ./src ./tools ./.project];
        };
        nativeBuildInputs = buildTools ++ [modustool];
        buildPhase = ''
          export HOME=$TMPDIR
          mkdir -p build
          modustool check
        '';
        installPhase = ''
          cp build/test_output.txt $out
        '';
      }
      // firmware
      # The source fonts: a test of the tool reads the feature "zero" of Paper Mono in them.
      // vectorFontSources);
  in {
    formatter.${system} = pkgs.alejandra;

    checks.${system} = {
      pre-commit = preCommitCheck;
      boot-test = bootTest;
    };

    devShells.${system} = {
      default = pkgs.mkShell ({
          # ffmpeg: the command "film" of modustool. sops: the keys of the
          # publisher in secrets/production.yaml (secrets/README.md).
          packages = buildTools ++ [modustool pkgs.ffmpeg pkgs.sops] ++ preCommitCheck.enabledPackages;
          inherit (preCommitCheck) shellHook;
        }
        // firmware
        // vectorFontSources);

      # The shell of a developer who builds a module of their own project:
      # the build tools and the command "modustool", with no hook of this
      # repository. The default shell installs the hooks of this repository
      # in the repository where it starts.
      module = pkgs.mkShell {
        packages = buildTools ++ [modustool];
      };
    };
  };
}
