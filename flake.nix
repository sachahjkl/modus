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
    # Node 24 runs the host of the browser machine: the tests of its stage
    # tracker in "modustool check", and "modustool browser-machine boot" in
    # the development shell. Only those two take it, so no other derivation
    # changes with it. The slim package: no npm.
    browserMachineHost = pkgs.nodejs-slim_24;

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
      # The folder of the BDF files of the font (8x16, 12x24, 16x32, 32x64), for
      # the command "font" of modustool.
      FONT_SOURCE = "${pkgs.spleen}/share/fonts/misc";
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
        "noto_sans=${pkgs.noto-fonts}/share/fonts/noto/NotoSans.ttf"
      ];
      # The script fonts (src/md/features/script_fonts.md): whole files,
      # for the command "script_fonts" and the host tests of the text.
      SCRIPT_FONT_SOURCES = builtins.concatStringsSep ";" [
        "noto_sans_hebrew=${pkgs.noto-fonts}/share/fonts/noto/NotoSansHebrew.ttf"
        "noto_sans_arabic=${pkgs.noto-fonts}/share/fonts/noto/NotoSansArabic.ttf"
        "noto_sans_symbols_2=${pkgs.noto-fonts}/share/fonts/noto/NotoSansSymbols2-Regular.otf"
        "noto_emoji=${pkgs.noto-fonts-monochrome-emoji}/share/fonts/noto/NotoEmoji.ttf"
        "noto_sans_cjk=${pkgs.noto-fonts-cjk-sans}/share/fonts/opentype/noto-cjk/NotoSansCJK-VF.otf.ttc"
        "noto_sans_thai=${pkgs.noto-fonts}/share/fonts/noto/NotoSansThai.ttf"
        "noto_sans_devanagari=${pkgs.noto-fonts}/share/fonts/noto/NotoSansDevanagari.ttf"
        "noto_sans_bengali=${pkgs.noto-fonts}/share/fonts/noto/NotoSansBengali.ttf"
        "noto_sans_gurmukhi=${pkgs.noto-fonts}/share/fonts/noto/NotoSansGurmukhi.ttf"
        "noto_sans_gujarati=${pkgs.noto-fonts}/share/fonts/noto/NotoSansGujarati.ttf"
        "noto_sans_oriya=${pkgs.noto-fonts}/share/fonts/noto/NotoSansOriya.ttf"
        "noto_sans_tamil=${pkgs.noto-fonts}/share/fonts/noto/NotoSansTamil.ttf"
        "noto_sans_telugu=${pkgs.noto-fonts}/share/fonts/noto/NotoSansTelugu.ttf"
        "noto_sans_kannada=${pkgs.noto-fonts}/share/fonts/noto/NotoSansKannada.ttf"
        "noto_sans_malayalam=${pkgs.noto-fonts}/share/fonts/noto/NotoSansMalayalam.ttf"
      ];
      # The Unicode Character Database, for the command "unicode_tables"
      # (src/md/features/written_shaping.md).
      UNICODE_DATA_SOURCE = "${pkgs.unicode-character-database}/share/unicode";
    };

    # chibicc, the C compiler of the module c_compiler: its source at one
    # commit, the patches of the system, and the files of the system beside
    # it, as one folder of the store. The tool compiles each .c file at the
    # top of the folder; the variable CHIBICC_SOURCE names it
    # (src/md/infrastructure/outside_source.md). The repository holds no
    # source file of the work. The include files of chibicc become a C
    # table, so the module reads no file.
    chibiccSource = pkgs.stdenvNoCC.mkDerivation {
      name = "chibicc-source";
      src = pkgs.fetchFromGitHub {
        owner = "rui314";
        repo = "chibicc";
        rev = "90d1f7f199cc55b13c7fdb5839d1409806633fdb";
        hash = "sha256-sGSPQv9JPXTnyv+7CnmzWq1objCJRctK4wKII8GM26s=";
      };
      # The patches, in the order of their names.
      patches = map (name: ./src/outside/chibicc/patches + "/${name}") (builtins.attrNames (builtins.readDir ./src/outside/chibicc/patches));
      dontConfigure = true;
      dontBuild = true;
      installPhase = ''
        runHook preInstall
        mkdir -p $out/libc/include $out/self_host
        # main.c is not copied: the entry of the system takes its place.
        cp chibicc.h codegen.c hashmap.c parse.c preprocess.c strings.c tokenize.c type.c unicode.c $out/
        cp ${./src/outside/chibicc/system}/* $out/
        cp ${./src/outside/chibicc/libc}/*.c $out/
        cp ${./src/outside/chibicc/libc/include}/*.h $out/libc/include/
        # The units that chibicc compiles in when it builds itself, and the
        # module of clang does not: `modustool c-self-host` reads them.
        cp ${./src/outside/chibicc/self_host}/* $out/self_host/
        {
          echo '// This file is the output of the flake: the include files of chibicc, as a table.'
          echo '#include "include_table.h"'
          echo 'const Include_File include_files[] = {'
          for header in include/*.h; do
            echo "  {\"$header\","
            sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/^/    "/' -e 's/$/\\n"/' "$header"
            echo '  },'
          done
          echo '  {0, 0},'
          echo '};'
        } > $out/include_table.c
        runHook postInstall
      '';
    };

    # The guest image of the process linux (src/md/features/linux_shell.md):
    # the bzImage of Nixpkgs and a static busybox, of which the tool makes an
    # initial archive. The host test of the boot protocol loads the kernel,
    # and the test part linux writes both into the private store linux of
    # its data disk. No module and no system image holds them: a guest image
    # is data in a store.
    guestImages = {
      MODUS_LINUX_KERNEL_IMAGE = "${pkgs.linux}/bzImage";
      MODUS_LINUX_GUEST_BUSYBOX = "${pkgs.pkgsStatic.busybox}/bin/busybox";
    };

    # The folders of the store of the outside sources, for the tool: each
    # shell and the check set them.
    outsideSources = {
      CHIBICC_SOURCE = "${chibiccSource}";
    };

    # The C programs of others that the host test of src/outside/c_programs
    # builds into modules: each recipe of src/outside/c_programs/recipes
    # names its archive, its hash, its root and its patches, and the flake
    # reads them from there, so the hash is written once. Each folder of the
    # store is the root of the archive, patched; the variables SQLITE_SOURCE,
    # LUA_SOURCE and ZSTD_SOURCE name them. Only the host checks and the
    # default shell read them: no module of the system build holds them.
    cProgramRecipe = name: let
      lines = builtins.filter (line: builtins.isString line && line != "" && builtins.substring 0 1 line != "#") (builtins.split "\n" (builtins.readFile (./src/outside/c_programs/recipes + "/${name}.recipe")));
      pairs = builtins.filter (pair: pair != null) (map (line: builtins.match "([a-z_]+): (.*)" line) lines);
      valuesOf = key: map (pair: builtins.elemAt pair 1) (builtins.filter (pair: builtins.head pair == key) pairs);
      single = key: builtins.head (valuesOf key);
    in
      pkgs.stdenvNoCC.mkDerivation {
        name = "${name}-${single "version"}-source";
        src = pkgs.fetchurl {
          url = single "source";
          hash = single "source_hash";
        };
        nativeBuildInputs = lib.optional (single "unpack" == "zip") pkgs.unzip;
        sourceRoot = single "root";
        patches = map (patch: ./src/outside/c_programs + "/${patch}") (valuesOf "patch");
        dontConfigure = true;
        dontBuild = true;
        installPhase = ''
          runHook preInstall
          cp -r . $out
          runHook postInstall
        '';
      };
    cProgramSources = {
      SQLITE_SOURCE = "${cProgramRecipe "sqlite"}";
      LUA_SOURCE = "${cProgramRecipe "lua"}";
      ZSTD_SOURCE = "${cProgramRecipe "zstd"}";
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
    # library of the project, the kernel parts (the tool reads two of
    # them) and the source library of the tool, whose packages import
    # each other through it, and the custom attribute log_fact of a fact
    # type, into a file of its own that it then moves: a compile that
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
        (cd "$system" && odin build tools/modustool -vet -collection:modus=src/library/modus -collection:internal=src/library/internal -collection:modulus=src/modulus -collection:modustool=tools/modustool -custom-attribute:log_fact,enum_getters,optional_parameters,member_texts -out:build/tool/modustool.first && mv build/tool/modustool.first build/tool/modustool) || exit 1
      fi
      exec "$system/build/tool/modustool" "$@"
    '';

    # The files that the compile of the tool reads in the repository: the
    # sources of its package, of the two source libraries, of the kernel parts
    # (each folder under src/modulus, not the kernel), and the fonts
    # that a fuzz target loads. A host test is not a source of the binary:
    # its name ends with _test, before the suffixes of a platform that the
    # compiler reads (blend_vectors_test_amd64.odin).
    sourcesOfOdin = inputs.nixpkgs.lib.fileset.fileFilter (file: file.hasExt "odin" && builtins.match ".*_test(_[a-z0-9]+)*\\.odin" file.name == null);
    kernelParts = map (name: ./src/modulus + "/${name}") (builtins.attrNames (inputs.nixpkgs.lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./src/modulus)));
    # The cryptography of the library links the memory procedures of the
    # host in assembly, which nasm assembles at the compile of the tool; that
    # file includes the memory procedures of the system.
    toolSources = inputs.nixpkgs.lib.fileset.unions ([(sourcesOfOdin ./tools/modustool) ./tools/modustool/build/browser_machine (sourcesOfOdin ./src/library) (inputs.nixpkgs.lib.fileset.fileFilter (file: file.hasExt "asm") ./src/runtime) ./resources/fonts/commit_mono.ttf ./resources/fonts/b612.ttf ./resources/fonts/b612_bold.ttf ./resources/fonts/paper_mono.ttf ./resources/fonts/paper_mono_semibold.ttf ./resources/fonts/noto_sans.ttf] ++ map sourcesOfOdin kernelParts);

    # The tool as a derivation of its own, from a set of its sources: Nix
    # builds it again only when a file of the set changes. It never
    # compiles itself: its sources are the inputs of the derivation.
    # -show-timings prints the time of each phase of the compiler in the
    # log of the build, as a measure.
    toolBinaryOf = name: fileset:
      pkgs.stdenvNoCC.mkDerivation {
        inherit name;
        src = inputs.nixpkgs.lib.fileset.toSource {
          root = ./.;
          inherit fileset;
        };
        nativeBuildInputs = [odin pkgs.nasm];
        buildPhase = ''
          export HOME=$TMPDIR
          odin build tools/modustool -vet -collection:modus=src/library/modus -collection:internal=src/library/internal -collection:modulus=src/modulus -collection:modustool=tools/modustool -custom-attribute:log_fact,enum_getters,optional_parameters,member_texts -define:TOOL_BUILDS_ITSELF=false -show-timings -out:modustool
        '';
        installPhase = ''
          install -D modustool $out/bin/modustool
        '';
      };

    # The whole tool: the check, the release shell and the package run it.
    modustoolBinary = toolBinaryOf "modustool" toolSources;

    # The files of the scenario of each test part, by their names in the
    # folder of the machine test (tools/modustool/machine/test_part_files.json).
    # A file that no part names is of the core of the tool.
    machineToolFolder = ./tools/modustool/machine;
    testPartFiles = builtins.fromJSON (builtins.readFile ./tools/modustool/machine/test_part_files.json);
    partFilesOf = names: map (name: machineToolFolder + "/${name}") names;
    everyPartFile = partFilesOf (inputs.nixpkgs.lib.unique (builtins.concatLists (builtins.attrValues testPartFiles)));
    toolCoreSources = inputs.nixpkgs.lib.fileset.difference toolSources (inputs.nixpkgs.lib.fileset.unions everyPartFile);

    # The binary of the tool of one test part: the core and the files of that
    # part alone. A part registers its run from its own files, so the binary
    # runs that part only, and a change of the scenario of one part builds
    # the binary of that part only
    # (src/md/infrastructure/full_check.md, "A binary of the tool for each part").
    partToolBinaries = builtins.mapAttrs (part: names:
      toolBinaryOf "modustool-part-${part}" (inputs.nixpkgs.lib.fileset.unions ([toolCoreSources] ++ partFilesOf names)))
    testPartFiles;

    # The check `boot-test` is the join of several derivations, so that Nix
    # runs again only what a change reaches: a whole build that gives the
    # test inputs, the test inputs named by the hash of their bytes, one
    # derivation for each test part, and the host checks. It is the one run
    # of the machine test of the full check: its output holds the pictures
    # and the logs, which `modustool screenshots` takes from the store
    # (src/md/infrastructure/full_check.md, "The derivations of the check").
    lib = inputs.nixpkgs.lib;

    # The files that a build or a check can read: the host tests of
    # `modustool site` read README.md, flake.lock and the Markdown documents;
    # the check of the source paths in the documents reads AGENTS.md too;
    # `modustool news check` reads news/, and the film that a news entry names
    # (docs/films: absent in a tree where no entry names a film); the check of
    # the font of the name of the mark reads LICENSE, whose text the font
    # carries; the build reads the guides for the pages of the manual.
    checkFiles = lib.fileset.unions [./flake.nix ./flake.lock ./CHANGELOG.md ./ROADMAP.md ./CONTRIBUTING.md ./changelog.d ./news ./README.md ./AGENTS.md ./LICENSE (lib.fileset.fileFilter (file: file.hasExt "md") ./docs) (lib.fileset.maybeMissing ./docs/films) ./resources ./src ./tools ./.project];

    # A whole build of the tree, then the test inputs and the hash of their
    # folder, as Nix hashes a path, and the names of the test parts, in the
    # order of the table of the tool. Its output changes with any change of
    # the tree; the derivations of the parts depend on the hash of its test
    # inputs only, through testInputs.
    systemBuild = pkgs.stdenvNoCC.mkDerivation ({
        name = "modus-system-build";
        src = lib.fileset.toSource {
          root = ./.;
          fileset = checkFiles;
        };
        nativeBuildInputs = buildTools ++ [modustoolBinary pkgs.nix];
        buildPhase = ''
          export HOME=$TMPDIR
          mkdir -p build
          modustool build whole
        '';
        installPhase = ''
          modustool test_inputs $out
          nix-hash --type sha256 --base32 $out/test_inputs | tr -d '\n' > $out/test_inputs.sha256
        '';
      }
      // firmware
      // outsideSources);

    # The test inputs as a fixed-output derivation: Nix names it by the hash
    # of its bytes, which the evaluation reads from systemBuild (an import
    # from a derivation). A derivation that depends on it depends on that
    # hash alone: two trees whose builds give the same bytes give one
    # testInputs, and Nix runs no part again.
    testInputs = pkgs.stdenvNoCC.mkDerivation {
      name = "modus-test-inputs";
      outputHashMode = "recursive";
      outputHashAlgo = "sha256";
      outputHash = builtins.readFile "${systemBuild}/test_inputs.sha256";
      buildCommand = "cp -r ${systemBuild}/test_inputs $out";
    };

    # The names of the test parts: the table of the tool is the one list.
    testPartNames = builtins.fromJSON (builtins.readFile "${systemBuild}/test_parts.json");

    # What a test part reads of the sources at its run: the sources of the
    # system and the resources, with no host test and no intent file, so a
    # change of a test or of a design runs no machine again.
    isTestFile = file: builtins.match ".*_test(_[a-z0-9]+)*\\.odin" file.name != null;
    partSources = lib.fileset.toSource {
      root = ./.;
      fileset = lib.fileset.difference (lib.fileset.unions [./src ./resources]) (lib.fileset.unions [./src/md (lib.fileset.fileFilter isTestFile ./src)]);
    };

    # One derivation for each test part: the part alone, on the test inputs,
    # with no build, with the binary of the tool of that part. The tool needs
    # the mark of the root of the repository, flake.nix, which the part does
    # not read: an empty file stands for it, so a change of the flake file
    # runs no part again. A part that the manifest of the scenario files
    # does not name stops the evaluation here, with its name.
    machineTestPart = part:
      pkgs.stdenvNoCC.mkDerivation ({
          name = "machine-test-${part}";
          src = partSources;
          nativeBuildInputs = buildTools ++ [partToolBinaries.${part}];
          # /dev/kvm in the sandbox. Without it QEMU falls back to TCG, which
          # takes every register write: the self test of a refused register
          # then fails, and the thread counters have nothing to try
          # (src/md/features/processor_counters.md).
          requiredSystemFeatures = ["kvm"];
          buildPhase = ''
            export HOME=$TMPDIR
            touch flake.nix
            modustool test ${part} from ${testInputs}
          '';
          # The logs of the machines, the times of the part, the count of
          # its checks, and its pictures.
          installPhase = ''
            mkdir -p $out/logs $out/screenshots
            cp build/*.txt $out/logs/
            find build/screenshots -maxdepth 1 -name '*.png' -exec cp {} $out/screenshots/ \;
          '';
        }
        // guestImages
        // firmware
        // outsideSources);
    testParts = lib.genAttrs testPartNames machineTestPart;

    # The names of the pictures of docs/screenshots, not their bytes: the
    # checks read which pictures exist and that each is a PNG with a size
    # (the README, the news, the pages of the site), so the build writes one
    # PNG of one pixel under each name. `modustool screenshots` writes new
    # bytes into these files at each run; with the names only, the source of
    # the check stays the same, so the check that it built stays in the store
    # whatever the order of the two commands of the full check. A new name is
    # a new source.
    screenshotNames = builtins.filter (name: inputs.nixpkgs.lib.hasSuffix ".png" name) (builtins.attrNames (builtins.readDir ./docs/screenshots));

    # modustool check with no machine: the host code passes -vet and its
    # tests, the fuzz targets, the checks of the sources, and a second build
    # that gives the same bytes. The check of the README needs the names of
    # its pictures (screenshotNames).
    hostChecks = pkgs.stdenvNoCC.mkDerivation ({
        name = "modus-host-checks";
        src = lib.fileset.toSource {
          root = ./.;
          fileset = checkFiles;
        };
        inherit screenshotNames;
        nativeBuildInputs = buildTools ++ [modustoolBinary browserMachineHost];
        buildPhase = ''
          export HOME=$TMPDIR
          mkdir -p build docs/screenshots
          for name in $screenshotNames; do
            echo iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg== | base64 -d > "docs/screenshots/$name"
          done
          modustool check without_machines
        '';
        # The record of the second build and the count of the checks.
        installPhase = ''
          mkdir -p $out/logs
          cp build/*.txt $out/logs/
        '';
      }
      // firmware
      # The source fonts: a test of the tool reads the feature "zero" of Paper Mono in them.
      // vectorFontSources
      // outsideSources
      // cProgramSources);

    # The join of the host checks and of every test part, in the layout that
    # `modustool screenshots` reads: logs/ and screenshots/. The tool refuses
    # a join that lacks a part, or where two parts wrote one file.
    # partOutputs and partDerivations are read by `modustool screenshots` (the
    # parts that Nix takes from the store), `modustool part_cache` (the
    # proof that a change of a document runs no part again) and `modustool
    # failed_parts` (the parts that failed, after a build with --keep-going).
    bootTest = pkgs.stdenvNoCC.mkDerivation {
      name = "kernel-boot-test";
      dontUnpack = true;
      nativeBuildInputs = [modustoolBinary];
      buildPhase = ''
        touch flake.nix
        modustool test_join $out ${hostChecks} ${lib.concatMapStringsSep " " (part: "${part}=${testParts.${part}}") testPartNames}
      '';
      dontInstall = true;
      passthru = {
        partOutputs = lib.mapAttrs (_: partCheck: partCheck.outPath) testParts;
        partDerivations = lib.mapAttrs (_: partCheck: partCheck.drvPath) testParts;
        # The binary of the tool of each part. Its evaluation builds nothing:
        # `modustool part_cache` compares these without a whole build.
        partToolDerivations = lib.mapAttrs (_: binary: binary.drvPath) partToolBinaries;
        systemBuildDerivation = systemBuild.drvPath;
        # `modustool failed_parts` lists the host checks beside the parts.
        hostChecksOutput = hostChecks.outPath;
        hostChecksDerivation = hostChecks.drvPath;
      };
    };
  in {
    formatter.${system} = pkgs.alejandra;

    packages.${system} = {
      default = modustoolBinary;
      modustool = modustoolBinary;
    };

    checks.${system} = {
      pre-commit = preCommitCheck;
      boot-test = bootTest;
    };

    devShells.${system} = {
      default = pkgs.mkShell ({
          # ffmpeg: the command "film" of modustool. sops: the keys of the
          # publisher in secrets/production.yaml (secrets/README.md).
          packages = buildTools ++ [modustool browserMachineHost pkgs.ffmpeg pkgs.sops] ++ preCommitCheck.enabledPackages;
          inherit (preCommitCheck) shellHook;
        }
        // guestImages
        // firmware
        // ownerPointerTheme
        // vectorFontSources
        // outsideSources
        // cProgramSources);

      # The shell of the release workflow: the build tools and the firmware,
      # with no pointer theme of the owner and no hook. `modustool release
      # image` makes the theme of the system only in any shell; this shell
      # also keeps the workflow from fetching the theme of the owner. Its
      # tool is the binary of the check, built from the same sources.
      release = pkgs.mkShell ({
          packages = buildTools ++ [modustoolBinary];
        }
        // firmware
        // outsideSources);

      # The shell of a developer who builds a module of their own project:
      # the build tools and the command "modustool", with no hook of this
      # repository. The default shell installs the hooks of this repository
      # in the repository where it starts.
      module = pkgs.mkShell ({
          packages = buildTools ++ [modustool];
        }
        // outsideSources);
    };
  };
}
