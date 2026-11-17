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

    # QEMU with no io_uring: its main loop then waits on epoll. With io_uring,
    # QEMU 10.2 sometimes misses the wake-up of a finished request, so the
    # firmware waits 135 s for the answer of the software TPM and cancels it
    # (https://gitlab.com/qemu-project/qemu/-/work_items/4581;
    # docs/TRUSTED_BOOT.md, "The machines of the TPM"). One target: the
    # system emulates x86-64 only, and each other target only adds build time.
    qemu = pkgs.qemu.override {
      uringSupport = false;
      hostCpuTargets = ["x86_64-softmmu"];
    };

    # What tools/modustool needs on the path.
    # llc comes from the LLVM of the Odin compiler (18): Odin writes LLVM IR, and
    # llc makes each object with frame pointers.
    # openssl: its QUIC client is the peer of the test "quic-real" of modustool.
    # swtpm: the software TPM of the machines of "test trusted_boot" and
    # "test principals".
    # sbsigntool (sbsign): signs the boot program for Secure Boot.
    # virt-firmware (virt-fw-vars): enrols the certificate of the firmware
    # signing key in a variable store of the firmware, with Secure Boot on.
    # openssl also makes the firmware signing key ("modustool key new").
    # zstd: compresses the release image ("modustool release image") and
    # decompresses it for its machine of "test trusted_boot".
    # clang of LLVM 18, the one that the Odin compiler links with: it links
    # the instrumented child of the fuzzing from the objects that llc made,
    # with the flags that the compiler prints (src/md/infrastructure/fuzzing.md).
    buildTools = [odin llvm pkgs.llvmPackages.lld pkgs.llvmPackages_18.clang pkgs.nasm qemu pkgs.coreutils pkgs.openssl pkgs.swtpm pkgs.sbsigntool pkgs.python3Packages.virt-firmware pkgs.zstd];

    # The pointer theme of the owner (docs/POINTERS.md): "Posy's Cursor", the
    # package of nixpkgs, pinned by flake.lock. Its license is CC-BY-NC-4.0,
    # which nixpkgs marks unfree and not redistributable: this one package is
    # allowed by its name. The repository holds no file of the theme: the
    # tool converts it at each build into build/pointers. Only the default
    # development shell names it: the checks and the shell of a release do
    # not, so a release image never holds it and the release workflow never
    # fetches it (src/md/infrastructure/release_image.md).
    pointerTheme =
      (import inputs.nixpkgs {
        inherit system;
        config.allowUnfreePredicate = package: inputs.nixpkgs.lib.getName package == "posy-cursors";
      }).posy-cursors;

    # The firmware of the machines of the measure and of the machine of the
    # TPM with Secure Boot off: the TPM driver without Secure Boot, so
    # without system management mode (docs/TRUSTED_BOOT.md, "The machines of
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
      # management mode of QEMU), for the machines of Secure Boot and of the
      # keys sealed by the TPM. Its
      # variable store has no key; the build writes a copy with the
      # certificate of the firmware signing key enrolled and Secure Boot on.
      OVMF_FULL_CODE = "${pkgs.OVMFFull.fd}/FV/OVMF_CODE.fd";
      OVMF_FULL_VARS = "${pkgs.OVMFFull.fd}/FV/OVMF_VARS.fd";
      # The source of the font, for the command "font" of modustool.
      FONT_SOURCE = "${pkgs.spleen}/share/fonts/misc/spleen-8x16.bdf";
    };

    # The Xcursor folder of the pointer theme of the owner, for the build in
    # the default development shell only.
    ownerPointerTheme = {
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

    # The command "modustool" of the development shells: it runs the
    # binary build/tool/modustool of the folder of the project, which
    # compiles itself again when the build key of its sources changes
    # (src/md/infrastructure/repository_layout.md, "The tool built once").
    # With no binary, the command compiles the first one, with the source
    # library of the project and the kernel parts (the tool reads two of
    # them), into a file of its own that it then moves: a compile that
    # stops leaves no binary that cannot run.
    # With MODUS_SYSTEM set, the folder of the project is that folder and
    # the command runs where it is typed: the folder of another project,
    # for the command "module-build"
    # (docs/TOOLS.md, "A module from a source outside the repository").
    modustool = pkgs.writeShellScriptBin "modustool" ''
      system="''${MODUS_SYSTEM:-$PWD}"
      if [ ! -x "$system/build/tool/modustool" ]; then
        mkdir -p "$system/build/tool"
        # The compiler reads the paths of the tool from the folder of the system.
        (cd "$system" && odin build tools/modustool -vet -collection:modus=src/library -collection:kernel=src/kernel -out:build/tool/modustool.first && mv build/tool/modustool.first build/tool/modustool) || exit 1
      fi
      exec "$system/build/tool/modustool" "$@"
    '';

    # The files that the compile of the tool reads in the repository: the
    # sources of its package, of the source library, of the kernel parts
    # (each folder under src/kernel, not the kernel), of the module
    # cryptography that the peer imports by a relative path, and the font
    # that a fuzz target loads. A host test is not a source of the binary:
    # its name ends with _test, before the suffixes of a platform that the
    # compiler reads (blend_vectors_test_amd64.odin).
    sourcesOfOdin = inputs.nixpkgs.lib.fileset.fileFilter (file: file.hasExt "odin" && builtins.match ".*_test(_[a-z0-9]+)*\\.odin" file.name == null);
    kernelParts = map (name: ./src/kernel + "/${name}") (builtins.attrNames (inputs.nixpkgs.lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./src/kernel)));
    # The cryptography of the library links the memory procedures of the
    # host in assembly, which nasm assembles at the compile of the tool; that
    # file includes the memory procedures of the system.
    toolSources = inputs.nixpkgs.lib.fileset.unions ([(sourcesOfOdin ./tools/modustool) (sourcesOfOdin ./src/library) (sourcesOfOdin ./src/modules/libraries/cryptography) (inputs.nixpkgs.lib.fileset.fileFilter (file: file.hasExt "asm") ./src/runtime) ./resources/fonts/commit_mono.ttf] ++ map sourcesOfOdin kernelParts);

    # The tool as a derivation of its own: the check and the release shell
    # run this binary, and Nix builds it again only when a file of
    # toolSources changes. It never compiles itself: its sources are the
    # inputs of the derivation. -show-timings prints the time of each
    # phase of the compiler in the log of the build, as a measure.
    modustoolBinary = pkgs.stdenvNoCC.mkDerivation {
      name = "modustool";
      src = inputs.nixpkgs.lib.fileset.toSource {
        root = ./.;
        fileset = toolSources;
      };
      nativeBuildInputs = [odin pkgs.nasm];
      buildPhase = ''
        export HOME=$TMPDIR
        odin build tools/modustool -vet -collection:modus=src/library -collection:kernel=src/kernel -define:TOOL_BUILDS_ITSELF=false -show-timings -out:modustool
      '';
      installPhase = ''
        install -D modustool $out/bin/modustool
      '';
    };

    # modustool check: the host code passes -vet and its tests, the system builds,
    # and the machine test passes under QEMU (console, desktop, tools). This is
    # the one run of the machine test of the full check: its output holds the
    # pictures and the logs, which `modustool screenshots` takes from the store
    # (src/md/infrastructure/full_check.md).
    # The names of the pictures of docs/screenshots, not their bytes: the
    # checks read which pictures exist and that each is a PNG with a size
    # (the README, the news, the pages of the site), so the build writes one
    # PNG of one pixel under each name. `modustool screenshots` writes new
    # bytes into these files at each run; with the names only, the source of
    # the check stays the same, so the check that it built stays in the store
    # whatever the order of the two commands of the full check. A new name is
    # a new source.
    screenshotNames = builtins.filter (name: inputs.nixpkgs.lib.hasSuffix ".png" name) (builtins.attrNames (builtins.readDir ./docs/screenshots));

    bootTest = pkgs.stdenvNoCC.mkDerivation ({
        name = "kernel-boot-test";
        src = inputs.nixpkgs.lib.fileset.toSource {
          root = ./.;
          # The host tests of `modustool site` read README.md, flake.lock and the Markdown documents; the check of the source paths in the documents reads AGENTS.md too; the check of the README needs the names of its pictures (screenshotNames); `modustool news check` reads news/, and the film that a news entry names (docs/films: absent in a tree where no entry names a film); the check of the font of the name of the mark reads LICENSE, whose text the font carries.
          fileset = inputs.nixpkgs.lib.fileset.unions [./flake.nix ./flake.lock ./CHANGELOG.md ./ROADMAP.md ./changelog.d ./news ./README.md ./AGENTS.md ./LICENSE (inputs.nixpkgs.lib.fileset.fileFilter (file: file.hasExt "md") ./docs) (inputs.nixpkgs.lib.fileset.maybeMissing ./docs/films) ./resources ./src ./tools ./.project];
        };
        inherit screenshotNames;
        nativeBuildInputs = buildTools ++ [modustoolBinary];
        # /dev/kvm in the sandbox. Without it QEMU falls back to TCG, which
        # takes every register write: the self test of a refused register
        # then fails, and the thread counters have nothing to try
        # (src/md/features/processor_counters.md).
        requiredSystemFeatures = ["kvm"];
        buildPhase = ''
          export HOME=$TMPDIR
          mkdir -p build docs/screenshots
          for name in $screenshotNames; do
            echo iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg== | base64 -d > "docs/screenshots/$name"
          done
          modustool check
        '';
        # The logs and the records of build/ (the logs of the machines, the
        # times of the test, the record of the second build, the count of
        # the checks) and the pictures of the test.
        installPhase = ''
          mkdir -p $out/logs $out/screenshots
          cp build/*.txt $out/logs/
          cp build/screenshots/*.png $out/screenshots/
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
        // ownerPointerTheme
        // vectorFontSources);

      # The shell of the release workflow: the build tools and the firmware,
      # with no pointer theme of the owner and no hook. `modustool release
      # image` makes the theme of the system only in any shell; this shell
      # also keeps the workflow from fetching the theme of the owner. Its
      # tool is the binary of the check, built from the same sources.
      release = pkgs.mkShell ({
          packages = buildTools ++ [modustoolBinary];
        }
        // firmware);

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
